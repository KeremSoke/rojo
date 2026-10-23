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

/* Wayland: wlr-gamma-control-unstable-v1, implemented by Wayfire (which
 * the MATE Wayland session runs on), sway, labwc, Hyprland and other
 * wlroots-based compositors.
 *
 * The compositor applies the ramp itself and gives one client exclusive
 * access per output, so nothing can reset it behind our back. When we
 * destroy a control the compositor restores the original ramp, so at
 * neutral we let go of the outputs entirely; that leaves them free for
 * other gamma tools and fullscreen games during the day.
 */

#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>
#include <wayland-client.h>

#include "wlr-gamma-control-unstable-v1-client-protocol.h"
#include "nl-gamma-private.h"

#define RETRY_INTERVAL (10 * G_USEC_PER_SEC)

typedef struct _WlGamma WlGamma;

typedef struct {
  WlGamma                      *wl;
  uint32_t                      global;
  struct wl_output             *output;
  struct zwlr_gamma_control_v1 *control;
  uint32_t                      size;
  gboolean                      failed;
  gint64                        failed_at;
  gboolean                      warned;
} WlOutput;

struct _WlGamma {
  NlGamma                              parent;
  struct wl_display                   *display;
  struct wl_registry                  *registry;
  struct zwlr_gamma_control_manager_v1 *manager;
  GPtrArray                           *outputs;
  gboolean                             active;
  double                               factors[3];
};

static void
output_drop_control (WlOutput *o)
{
  if (o->control)
    zwlr_gamma_control_v1_destroy (o->control);
  o->control = NULL;
  o->size = 0;
}

static void
output_free (WlOutput *o)
{
  output_drop_control (o);
  if (o->output)
    wl_output_destroy (o->output);
  g_free (o);
}

static void
output_set_ramp (WlOutput *o)
{
  WlGamma *wl = o->wl;
  if (!o->control || o->size == 0)
    return;

  size_t bytes = (size_t) o->size * 3 * sizeof (uint16_t);
  int fd = memfd_create ("rojo-gamma", MFD_CLOEXEC | MFD_ALLOW_SEALING);
  if (fd < 0)
    {
      g_warning ("memfd_create failed: %s", g_strerror (errno));
      return;
    }
  if (ftruncate (fd, bytes) < 0)
    {
      g_warning ("ftruncate failed: %s", g_strerror (errno));
      close (fd);
      return;
    }
  uint16_t *ramp = mmap (NULL, bytes, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
  if (ramp == MAP_FAILED)
    {
      g_warning ("mmap failed: %s", g_strerror (errno));
      close (fd);
      return;
    }
  for (guint c = 0; c < 3; c++)
    nl_gamma_fill_ramp (ramp + c * o->size, NULL, o->size, wl->factors[c]);
  munmap (ramp, bytes);
  fcntl (fd, F_ADD_SEALS, F_SEAL_SHRINK | F_SEAL_GROW | F_SEAL_WRITE | F_SEAL_SEAL);

  zwlr_gamma_control_v1_set_gamma (o->control, fd);
  close (fd);
}

static void
handle_gamma_size (void *data, struct zwlr_gamma_control_v1 *control, uint32_t size)
{
  WlOutput *o = data;
  o->size = size;
  o->warned = FALSE;
  if (size == 0)
    {
      /* The output can't do gamma (e.g. a virtual one); stop asking. */
      output_drop_control (o);
      o->failed = TRUE;
      o->failed_at = G_MAXINT64;
      return;
    }
  if (o->wl->active)
    output_set_ramp (o);
}

static void
handle_failed (void *data, struct zwlr_gamma_control_v1 *control)
{
  WlOutput *o = data;
  /* The protocol doesn't say why: another client has the output, or it
   * can't do gamma. We retry now and then, so only say it once. */
  if (!o->warned)
    g_message ("The compositor refused gamma control of an output; another program "
               "may be using it, or it doesn't support gamma");
  o->warned = TRUE;
  output_drop_control (o);
  o->failed = TRUE;
  o->failed_at = g_get_monotonic_time ();
  nl_gamma_emit (&o->wl->parent);
}

static const struct zwlr_gamma_control_v1_listener control_listener = {
  .gamma_size = handle_gamma_size,
  .failed = handle_failed,
};

static void
output_acquire (WlOutput *o)
{
  if (o->control || !o->wl->manager)
    return;
  if (o->failed && g_get_monotonic_time () - o->failed_at < RETRY_INTERVAL)
    return;
  o->failed = FALSE;
  o->control = zwlr_gamma_control_manager_v1_get_gamma_control (o->wl->manager, o->output);
  zwlr_gamma_control_v1_add_listener (o->control, &control_listener, o);
  /* The ramp is sent when gamma_size arrives. */
}

static void
handle_global (void *data, struct wl_registry *registry, uint32_t name,
               const char *interface, uint32_t version)
{
  WlGamma *wl = data;
  if (strcmp (interface, wl_output_interface.name) == 0)
    {
      WlOutput *o = g_new0 (WlOutput, 1);
      o->wl = wl;
      o->global = name;
      o->output = wl_registry_bind (registry, name, &wl_output_interface, 1);
      g_ptr_array_add (wl->outputs, o);
      if (wl->active)
        output_acquire (o);
      nl_gamma_emit (&wl->parent);
    }
  else if (strcmp (interface, zwlr_gamma_control_manager_v1_interface.name) == 0)
    {
      wl->manager = wl_registry_bind (registry, name, &zwlr_gamma_control_manager_v1_interface, 1);
    }
}

static void
handle_global_remove (void *data, struct wl_registry *registry, uint32_t name)
{
  WlGamma *wl = data;
  for (guint i = 0; i < wl->outputs->len; i++)
    {
      WlOutput *o = g_ptr_array_index (wl->outputs, i);
      if (o->global == name)
        {
          g_ptr_array_remove_index (wl->outputs, i);
          nl_gamma_emit (&wl->parent);
          return;
        }
    }
}

static const struct wl_registry_listener registry_listener = {
  .global = handle_global,
  .global_remove = handle_global_remove,
};

/* ---- NlGamma ---- */

static void
wl_free (NlGamma *gamma)
{
  WlGamma *wl = (WlGamma *) gamma;
  g_ptr_array_unref (wl->outputs);
  if (wl->manager)
    zwlr_gamma_control_manager_v1_destroy (wl->manager);
  if (wl->registry)
    wl_registry_destroy (wl->registry);
  if (wl->display)
    {
      wl_display_flush (wl->display);
      wl_display_disconnect (wl->display);
    }
  g_free (wl);
}

static int
wl_get_fd (NlGamma *gamma)
{
  return wl_display_get_fd (((WlGamma *) gamma)->display);
}

static gboolean
wl_dispatch (NlGamma *gamma)
{
  WlGamma *wl = (WlGamma *) gamma;
  if (wl_display_dispatch (wl->display) < 0)
    return FALSE;
  wl_display_flush (wl->display);
  return TRUE;
}

static gboolean
wl_apply (NlGamma *gamma, double r, double g, double b)
{
  WlGamma *wl = (WlGamma *) gamma;
  wl->factors[0] = r;
  wl->factors[1] = g;
  wl->factors[2] = b;
  wl->active = TRUE;
  for (guint i = 0; i < wl->outputs->len; i++)
    {
      WlOutput *o = g_ptr_array_index (wl->outputs, i);
      if (o->control)
        output_set_ramp (o);
      else
        output_acquire (o);
    }
  return wl_display_flush (wl->display) >= 0 || errno == EAGAIN;
}

static gboolean
wl_verify (NlGamma *gamma)
{
  WlGamma *wl = (WlGamma *) gamma;
  /* Nobody can change our ramps, but outputs we lost may be free again. */
  if (wl->active)
    {
      for (guint i = 0; i < wl->outputs->len; i++)
        output_acquire (g_ptr_array_index (wl->outputs, i));
      wl_display_flush (wl->display);
    }
  return TRUE;
}

static void
wl_force_reapply (NlGamma *gamma)
{
  WlGamma *wl = (WlGamma *) gamma;
  if (wl->active)
    wl_apply (gamma, wl->factors[0], wl->factors[1], wl->factors[2]);
}

static void
wl_release (NlGamma *gamma)
{
  WlGamma *wl = (WlGamma *) gamma;
  wl->active = FALSE;
  for (guint i = 0; i < wl->outputs->len; i++)
    {
      WlOutput *o = g_ptr_array_index (wl->outputs, i);
      output_drop_control (o);
      if (o->failed_at != G_MAXINT64)
        o->failed = FALSE;
    }
  wl_display_flush (wl->display);
}

static guint
wl_n_outputs (NlGamma *gamma)
{
  return ((WlGamma *) gamma)->outputs->len;
}

static guint
wl_n_busy (NlGamma *gamma)
{
  WlGamma *wl = (WlGamma *) gamma;
  guint n = 0;
  for (guint i = 0; i < wl->outputs->len; i++)
    {
      WlOutput *o = g_ptr_array_index (wl->outputs, i);
      if (o->failed && o->failed_at != G_MAXINT64)
        n++;
    }
  return n;
}

static const NlGammaClass wl_class = {
  .name = "wayland",
  .free = wl_free,
  .get_fd = wl_get_fd,
  .dispatch = wl_dispatch,
  .apply = wl_apply,
  .verify = wl_verify,
  .force_reapply = wl_force_reapply,
  .release = wl_release,
  .n_outputs = wl_n_outputs,
  .n_busy = wl_n_busy,
};

NlGamma *
nl_gamma_wayland_new (const char *display_name, GError **error)
{
  struct wl_display *display = wl_display_connect (display_name);
  if (!display)
    {
      g_set_error (error, NL_GAMMA_ERROR, NL_GAMMA_ERROR_NO_DISPLAY,
                   "cannot connect to Wayland display %s",
                   display_name ? display_name : "(default)");
      return NULL;
    }

  WlGamma *wl = g_new0 (WlGamma, 1);
  nl_gamma_init (&wl->parent, &wl_class);
  wl->parent.preserve_calibration = FALSE;
  wl->display = display;
  wl->outputs = g_ptr_array_new_with_free_func ((GDestroyNotify) output_free);
  wl->registry = wl_display_get_registry (display);
  wl_registry_add_listener (wl->registry, &registry_listener, wl);
  wl_display_roundtrip (display);

  if (!wl->manager)
    {
      wl_free (&wl->parent);
      g_set_error_literal (error, NL_GAMMA_ERROR, NL_GAMMA_ERROR_UNSUPPORTED,
                           "the compositor doesn't support wlr-gamma-control-unstable-v1");
      return NULL;
    }
  return &wl->parent;
}
