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

/* Setting the gamma ramps of every output, on X11 or Wayland.
 *
 * This is the only part of the daemon that depends on the display server.
 * Callers pass per-channel factors; each backend multiplies them into the
 * output's ramp and keeps it applied when outputs come and go.
 */

#pragma once

#include <glib.h>

G_BEGIN_DECLS

#define NL_GAMMA_ERROR (nl_gamma_error_quark ())

typedef enum {
  NL_GAMMA_ERROR_NO_DISPLAY,
  NL_GAMMA_ERROR_UNSUPPORTED,
  NL_GAMMA_ERROR_NOT_BUILT,
} NlGammaError;

typedef struct _NlGamma NlGamma;

/* Outputs were added or removed, or a gamma control was lost. */
typedef void (*NlGammaNotify) (gpointer user_data);

GQuark       nl_gamma_error_quark      (void);

NlGamma     *nl_gamma_x11_new          (const char *display_name, GError **error);
NlGamma     *nl_gamma_wayland_new      (const char *display_name, GError **error);
void         nl_gamma_free             (NlGamma *gamma);

const char  *nl_gamma_get_name         (NlGamma *gamma);
int          nl_gamma_get_fd           (NlGamma *gamma);
/* Handle events after the fd became readable. FALSE if the connection is gone. */
gboolean     nl_gamma_dispatch         (NlGamma *gamma);
void         nl_gamma_set_notify       (NlGamma *gamma, NlGammaNotify func, gpointer user_data);

/* Keep the ramps outputs had before we touched them (calibration curves
 * loaded by colord, xcalib, dispwin...) and scale those, instead of
 * starting from a linear ramp. X11 only; Wayland compositors don't expose
 * the current ramp. */
void         nl_gamma_set_preserve_calibration (NlGamma *gamma, gboolean preserve);

/* Scale every output's ramp by these factors (0..1). */
gboolean     nl_gamma_apply            (NlGamma *gamma, double r, double g, double b);
/* Check that nobody else changed the ramps since nl_gamma_apply(), and put
 * ours back if they did. Returns FALSE if they had been changed. */
gboolean     nl_gamma_verify           (NlGamma *gamma);
/* Re-send the ramps even where they look unchanged (after resume). */
void         nl_gamma_force_reapply    (NlGamma *gamma);
/* Restore the original ramps and stop holding the outputs. */
void         nl_gamma_release          (NlGamma *gamma);

guint        nl_gamma_get_n_outputs    (NlGamma *gamma);
/* Outputs whose gamma is held by another program (Wayland allows one). */
guint        nl_gamma_get_n_busy       (NlGamma *gamma);

G_END_DECLS
