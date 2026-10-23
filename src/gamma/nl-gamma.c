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

#include "nl-gamma-private.h"

G_DEFINE_QUARK (nl-gamma-error-quark, nl_gamma_error)

void
nl_gamma_init (NlGamma *gamma, const NlGammaClass *klass)
{
  gamma->klass = klass;
  gamma->preserve_calibration = TRUE;
}

void
nl_gamma_emit (NlGamma *gamma)
{
  if (gamma->notify)
    gamma->notify (gamma->notify_data);
}

void
nl_gamma_fill_ramp (uint16_t *out, const uint16_t *base, guint size, double factor)
{
  for (guint i = 0; i < size; i++)
    {
      double v = base ? base[i] : (size > 1 ? (double) i * 65535.0 / (size - 1) : 65535.0);
      out[i] = (uint16_t) CLAMP (v * factor + 0.5, 0.0, 65535.0);
    }
}

void
nl_gamma_free (NlGamma *gamma)
{
  if (gamma)
    gamma->klass->free (gamma);
}

const char *
nl_gamma_get_name (NlGamma *gamma)
{
  return gamma->klass->name;
}

int
nl_gamma_get_fd (NlGamma *gamma)
{
  return gamma->klass->get_fd (gamma);
}

gboolean
nl_gamma_dispatch (NlGamma *gamma)
{
  return gamma->klass->dispatch (gamma);
}

void
nl_gamma_set_notify (NlGamma *gamma, NlGammaNotify func, gpointer user_data)
{
  gamma->notify = func;
  gamma->notify_data = user_data;
}

void
nl_gamma_set_preserve_calibration (NlGamma *gamma, gboolean preserve)
{
  gamma->preserve_calibration = preserve;
}

gboolean
nl_gamma_apply (NlGamma *gamma, double r, double g, double b)
{
  return gamma->klass->apply (gamma, CLAMP (r, 0.0, 1.0), CLAMP (g, 0.0, 1.0), CLAMP (b, 0.0, 1.0));
}

gboolean
nl_gamma_verify (NlGamma *gamma)
{
  return gamma->klass->verify (gamma);
}

void
nl_gamma_force_reapply (NlGamma *gamma)
{
  gamma->klass->force_reapply (gamma);
}

void
nl_gamma_release (NlGamma *gamma)
{
  gamma->klass->release (gamma);
}

guint
nl_gamma_get_n_outputs (NlGamma *gamma)
{
  return gamma->klass->n_outputs (gamma);
}

guint
nl_gamma_get_n_busy (NlGamma *gamma)
{
  return gamma->klass->n_busy (gamma);
}

#ifndef HAVE_X11
NlGamma *
nl_gamma_x11_new (const char *display_name, GError **error)
{
  g_set_error_literal (error, NL_GAMMA_ERROR, NL_GAMMA_ERROR_NOT_BUILT,
                       "built without X11 support");
  return NULL;
}
#endif

#ifndef HAVE_WAYLAND
NlGamma *
nl_gamma_wayland_new (const char *display_name, GError **error)
{
  g_set_error_literal (error, NL_GAMMA_ERROR, NL_GAMMA_ERROR_NOT_BUILT,
                       "built without Wayland support");
  return NULL;
}
#endif
