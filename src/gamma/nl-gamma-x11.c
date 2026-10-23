/*
 * Copyright (C) 2026 Kerem Soke
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program.  If not, see <https://www.gnu.org/licenses/>.
 *
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

/* X11: RandR 1.3 CRTC gamma, as gnome-settings-daemon did through
 * libgnome-desktop before mutter took over.
 *
 * Unlike a compositor we can't stop other clients from setting the ramps,
 * so we remember what we set and verify it (games and video players reset
 * gamma on exit). We also remember each CRTC's original ramp, which holds
 * the monitor calibration if one was loaded, and scale that instead of
 * overwriting it. A copy of the originals is kept in $XDG_RUNTIME_DIR so a
 * crashed instance's leftover tint isn't mistaken for calibration.
 */

#include <string.h>
#include <xcb/xcb.h>
#include <xcb/randr.h>

#include "nl-gamma-private.h"

typedef struct {
  xcb_randr_crtc_t id;
  guint            size;
  uint16_t        *base;      /* r, g, b; the ramp before we touched it */
  uint16_t        *applied;   /* r, g, b; what we last set, or NULL */
  gboolean         seen;
} X11Crtc;

typedef struct {
  NlGamma           parent;
  xcb_connection_t *conn;
  xcb_window_t      root;
  uint8_t           event_base;
  GPtrArray        *crtcs;
  char             *state_path;
  gboolean          active;
  double            factors[3];
} X11Gamma;

static void
crtc_free (X11Crtc *crtc)
{
  g_free (crtc->base);
  g_free (crtc->applied);
  g_free (crtc);
}

static uint16_t *
read_ramp (X11Gamma *x, xcb_randr_crtc_t id, guint size)
{
  xcb_randr_get_crtc_gamma_reply_t *reply =
    xcb_randr_get_crtc_gamma_reply (x->conn, xcb_randr_get_crtc_gamma (x->conn, id), NULL);
  if (!reply || reply->size != size)
    {
      free (reply);
      return NULL;
    }
  uint16_t *ramp = g_new (uint16_t, 3 * size);
  memcpy (ramp, xcb_randr_get_crtc_gamma_red (reply), size * sizeof (uint16_t));
  memcpy (ramp + size, xcb_randr_get_crtc_gamma_green (reply), size * sizeof (uint16_t));
  memcpy (ramp + 2 * size, xcb_randr_get_crtc_gamma_blue (reply), size * sizeof (uint16_t));
  free (reply);
  return ramp;
}

static void
write_ramp (X11Gamma *x, X11Crtc *crtc, const uint16_t *ramp)
{
  xcb_randr_set_crtc_gamma (x->conn, crtc->id, crtc->size,
                            ramp, ramp + crtc->size, ramp + 2 * crtc->size);
}

/* Whether `ramp` is `base` with each channel scaled by some factor <= 1,
 * i.e. looks like something we produced from it. */
static gboolean
is_scaled_copy (const uint16_t *ramp, const uint16_t *base, guint size)
{
  for (guint c = 0; c < 3; c++)
    {
      const uint16_t *r = ramp + c * size, *b = base + c * size;
      if (b[size - 1] == 0)
        return FALSE;
      double f = (double) r[size - 1] / b[size - 1];
      if (f > 1.001)
        return FALSE;
      for (guint i = 0; i < size; i++)
        if (ABS ((double) r[i] - b[i] * f) > 0.01 * 65535 + 1)
          return FALSE;
    }
  return TRUE;
}

/* ---- originals saved for crash recovery: a(uaq) ---- */

static GHashTable *
load_saved (X11Gamma *x)
{
  GHashTable *saved = g_hash_table_new_full (NULL, NULL, NULL, (GDestroyNotify) g_variant_unref);
  gchar *data;
  gsize len;
  if (!g_file_get_contents (x->state_path, &data, &len, NULL))
    return saved;
  GVariant *v = g_variant_new_from_data (G_VARIANT_TYPE ("a(uaq)"), data, len, FALSE, g_free, data);
  GVariantIter iter;
  guint32 id;
  GVariant *ramp;
  g_variant_iter_init (&iter, v);
  while (g_variant_iter_next (&iter, "(u@aq)", &id, &ramp))
    g_hash_table_insert (saved, GUINT_TO_POINTER (id), ramp);
  g_variant_unref (v);
  return saved;
}

static void
save_originals (X11Gamma *x)
{
  GVariantBuilder b;
  g_variant_builder_init (&b, G_VARIANT_TYPE ("a(uaq)"));
  for (guint i = 0; i < x->crtcs->len; i++)
    {
      X11Crtc *crtc = g_ptr_array_index (x->crtcs, i);
      g_variant_builder_add (&b, "(u@aq)", crtc->id,
                             g_variant_new_fixed_array (G_VARIANT_TYPE_UINT16, crtc->base,
                                                        3 * crtc->size, sizeof (uint16_t)));
    }
  GVariant *v = g_variant_ref_sink (g_variant_builder_end (&b));
  g_autoptr(GError) error = NULL;
  if (!g_file_set_contents (x->state_path, g_variant_get_data (v), g_variant_get_size (v), &error))
    g_debug ("Cannot save original gamma ramps: %s", error->message);
  g_variant_unref (v);
}

/* ---- CRTCs ---- */

static X11Crtc *
find_crtc (X11Gamma *x, xcb_randr_crtc_t id)
{
  for (guint i = 0; i < x->crtcs->len; i++)
    {
      X11Crtc *crtc = g_ptr_array_index (x->crtcs, i);
      if (crtc->id == id)
        return crtc;
    }
  return NULL;
}

static void
enumerate (X11Gamma *x)
{
  xcb_randr_get_screen_resources_current_reply_t *res =
    xcb_randr_get_screen_resources_current_reply (
      x->conn, xcb_randr_get_screen_resources_current (x->conn, x->root), NULL);
  if (!res)
    return;

  for (guint i = 0; i < x->crtcs->len; i++)
    ((X11Crtc *) g_ptr_array_index (x->crtcs, i))->seen = FALSE;

  GHashTable *saved = NULL;
  gboolean added = FALSE;
  xcb_randr_crtc_t *ids = xcb_randr_get_screen_resources_current_crtcs (res);
  int n = xcb_randr_get_screen_resources_current_crtcs_length (res);
  for (int i = 0; i < n; i++)
    {
      xcb_randr_get_crtc_gamma_size_reply_t *sr =
        xcb_randr_get_crtc_gamma_size_reply (x->conn, xcb_randr_get_crtc_gamma_size (x->conn, ids[i]), NULL);
      guint size = sr ? sr->size : 0;
      free (sr);

      X11Crtc *crtc = find_crtc (x, ids[i]);
      if (crtc && crtc->size == size)
        {
          crtc->seen = TRUE;
          continue;
        }
      if (crtc)
        g_ptr_array_remove (x->crtcs, crtc);
      if (size < 2)
        continue;

      uint16_t *current = read_ramp (x, ids[i], size);
      if (!current)
        continue;
      if (!saved)
        saved = load_saved (x);

      crtc = g_new0 (X11Crtc, 1);
      crtc->id = ids[i];
      crtc->size = size;
      crtc->seen = TRUE;
      crtc->base = current;

      GVariant *old = g_hash_table_lookup (saved, GUINT_TO_POINTER (ids[i]));
      gsize old_len = 0;
      const uint16_t *old_ramp = old ? g_variant_get_fixed_array (old, &old_len, sizeof (uint16_t)) : NULL;
      if (old_ramp && old_len == 3 * size && memcmp (old_ramp, current, old_len * 2) != 0 &&
          is_scaled_copy (current, old_ramp, size))
        {
          g_message ("CRTC %u still has a tint from a previous run; restoring its original ramp", ids[i]);
          memcpy (crtc->base, old_ramp, old_len * sizeof (uint16_t));
        }
      g_ptr_array_add (x->crtcs, crtc);
      added = TRUE;
    }
  free (res);
  if (saved)
    g_hash_table_unref (saved);

  for (guint i = x->crtcs->len; i-- > 0;)
    if (!((X11Crtc *) g_ptr_array_index (x->crtcs, i))->seen)
      {
        g_ptr_array_remove_index (x->crtcs, i);
        added = TRUE;
      }

  if (added)
    save_originals (x);
}

/* ---- NlGamma ---- */

static void
x11_free (NlGamma *gamma)
{
  X11Gamma *x = (X11Gamma *) gamma;
  g_ptr_array_unref (x->crtcs);
  if (x->conn)
    xcb_disconnect (x->conn);
  g_free (x->state_path);
  g_free (x);
}

static int
x11_get_fd (NlGamma *gamma)
{
  return xcb_get_file_descriptor (((X11Gamma *) gamma)->conn);
}

static void
apply_all (X11Gamma *x, gboolean force)
{
  for (guint i = 0; i < x->crtcs->len; i++)
    {
      X11Crtc *crtc = g_ptr_array_index (x->crtcs, i);
      const uint16_t *base = x->parent.preserve_calibration ? crtc->base : NULL;
      g_autofree uint16_t *ramp = g_new (uint16_t, 3 * crtc->size);
      for (guint c = 0; c < 3; c++)
        nl_gamma_fill_ramp (ramp + c * crtc->size, base ? base + c * crtc->size : NULL,
                            crtc->size, x->factors[c]);
      if (!force && crtc->applied && memcmp (crtc->applied, ramp, 6 * crtc->size) == 0)
        continue;
      write_ramp (x, crtc, ramp);
      g_free (crtc->applied);
      crtc->applied = g_steal_pointer (&ramp);
    }
  xcb_flush (x->conn);
}

static gboolean x11_verify (NlGamma *gamma);

static gboolean
x11_dispatch (NlGamma *gamma)
{
  X11Gamma *x = (X11Gamma *) gamma;
  gboolean changed = FALSE;
  xcb_generic_event_t *ev;
  while ((ev = xcb_poll_for_event (x->conn)))
    {
      uint8_t type = ev->response_type & ~0x80;
      if (type == x->event_base + XCB_RANDR_SCREEN_CHANGE_NOTIFY ||
          type == x->event_base + XCB_RANDR_NOTIFY)
        changed = TRUE;
      free (ev);
    }
  if (xcb_connection_has_error (x->conn))
    return FALSE;
  if (changed)
    {
      g_debug ("RandR configuration changed");
      enumerate (x);
      /* Set new CRTCs, and put ours back where a mode set reset the ramp.
       * Compare rather than force, so we can't loop on our own writes. */
      if (x->active)
        {
          apply_all (x, FALSE);
          x11_verify (gamma);
        }
      nl_gamma_emit (gamma);
    }
  return TRUE;
}

static gboolean
x11_apply (NlGamma *gamma, double r, double g, double b)
{
  X11Gamma *x = (X11Gamma *) gamma;
  x->factors[0] = r;
  x->factors[1] = g;
  x->factors[2] = b;
  x->active = TRUE;
  apply_all (x, FALSE);
  return !xcb_connection_has_error (x->conn);
}

static gboolean
x11_verify (NlGamma *gamma)
{
  X11Gamma *x = (X11Gamma *) gamma;
  gboolean intact = TRUE;
  if (!x->active)
    return TRUE;
  for (guint i = 0; i < x->crtcs->len; i++)
    {
      X11Crtc *crtc = g_ptr_array_index (x->crtcs, i);
      if (!crtc->applied)
        continue;
      g_autofree uint16_t *current = read_ramp (x, crtc->id, crtc->size);
      if (current && memcmp (current, crtc->applied, 6 * crtc->size) != 0)
        {
          write_ramp (x, crtc, crtc->applied);
          intact = FALSE;
        }
    }
  if (!intact)
    xcb_flush (x->conn);
  return intact;
}

static void
x11_force_reapply (NlGamma *gamma)
{
  X11Gamma *x = (X11Gamma *) gamma;
  if (x->active)
    apply_all (x, TRUE);
}

static void
x11_release (NlGamma *gamma)
{
  X11Gamma *x = (X11Gamma *) gamma;
  if (!x->active)
    return;
  x->active = FALSE;
  for (guint i = 0; i < x->crtcs->len; i++)
    {
      X11Crtc *crtc = g_ptr_array_index (x->crtcs, i);
      if (!crtc->applied)
        continue;
      if (x->parent.preserve_calibration)
        {
          write_ramp (x, crtc, crtc->base);
        }
      else
        {
          g_autofree uint16_t *linear = g_new (uint16_t, 3 * crtc->size);
          for (guint c = 0; c < 3; c++)
            nl_gamma_fill_ramp (linear + c * crtc->size, NULL, crtc->size, 1.0);
          write_ramp (x, crtc, linear);
        }
      g_clear_pointer (&crtc->applied, g_free);
    }
  xcb_flush (x->conn);
}

static guint
x11_n_outputs (NlGamma *gamma)
{
  return ((X11Gamma *) gamma)->crtcs->len;
}

static guint
x11_n_busy (NlGamma *gamma)
{
  return 0;
}

static const NlGammaClass x11_class = {
  .name = "x11",
  .free = x11_free,
  .get_fd = x11_get_fd,
  .dispatch = x11_dispatch,
  .apply = x11_apply,
  .verify = x11_verify,
  .force_reapply = x11_force_reapply,
  .release = x11_release,
  .n_outputs = x11_n_outputs,
  .n_busy = x11_n_busy,
};

NlGamma *
nl_gamma_x11_new (const char *display_name, GError **error)
{
  int screen_num = 0;
  xcb_connection_t *conn = xcb_connect (display_name, &screen_num);
  if (xcb_connection_has_error (conn))
    {
      xcb_disconnect (conn);
      g_set_error (error, NL_GAMMA_ERROR, NL_GAMMA_ERROR_NO_DISPLAY,
                   "cannot connect to X display %s", display_name ? display_name : "(default)");
      return NULL;
    }

  const xcb_query_extension_reply_t *ext = xcb_get_extension_data (conn, &xcb_randr_id);
  xcb_randr_query_version_reply_t *ver = ext && ext->present
    ? xcb_randr_query_version_reply (conn, xcb_randr_query_version (conn, 1, 3), NULL)
    : NULL;
  if (!ver || (ver->major_version == 1 && ver->minor_version < 3))
    {
      free (ver);
      xcb_disconnect (conn);
      g_set_error_literal (error, NL_GAMMA_ERROR, NL_GAMMA_ERROR_UNSUPPORTED,
                           "the X server doesn't support RandR 1.3");
      return NULL;
    }
  free (ver);

  xcb_screen_iterator_t it = xcb_setup_roots_iterator (xcb_get_setup (conn));
  for (int i = 0; i < screen_num && it.rem; i++)
    xcb_screen_next (&it);

  X11Gamma *x = g_new0 (X11Gamma, 1);
  nl_gamma_init (&x->parent, &x11_class);
  x->conn = conn;
  x->root = it.data->root;
  x->event_base = ext->first_event;
  x->crtcs = g_ptr_array_new_with_free_func ((GDestroyNotify) crtc_free);

  g_autofree char *display = g_strdup (display_name ? display_name : g_getenv ("DISPLAY"));
  g_autofree char *safe = g_strcanon (g_strdup (display ? display : "default"),
                                      G_CSET_A_2_Z G_CSET_a_2_z G_CSET_DIGITS "-_.", '_');
  g_autofree char *name = g_strdup_printf ("rojo-x11-%s.gamma", safe);
  x->state_path = g_build_filename (g_get_user_runtime_dir (), name, NULL);

  xcb_randr_select_input (conn, x->root,
                          XCB_RANDR_NOTIFY_MASK_SCREEN_CHANGE |
                          XCB_RANDR_NOTIFY_MASK_CRTC_CHANGE |
                          XCB_RANDR_NOTIFY_MASK_OUTPUT_CHANGE);
  enumerate (x);
  xcb_flush (conn);

  if (x->crtcs->len == 0)
    g_message ("No CRTCs with adjustable gamma; Night Light will wait for one");
  return &x->parent;
}
