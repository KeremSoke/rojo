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

#pragma once

#include <stdint.h>
#include "nl-gamma.h"

typedef struct {
  const char *name;
  void      (*free)          (NlGamma *gamma);
  int       (*get_fd)        (NlGamma *gamma);
  gboolean  (*dispatch)      (NlGamma *gamma);
  gboolean  (*apply)         (NlGamma *gamma, double r, double g, double b);
  gboolean  (*verify)        (NlGamma *gamma);
  void      (*force_reapply) (NlGamma *gamma);
  void      (*release)       (NlGamma *gamma);
  guint     (*n_outputs)     (NlGamma *gamma);
  guint     (*n_busy)        (NlGamma *gamma);
} NlGammaClass;

struct _NlGamma {
  const NlGammaClass *klass;
  NlGammaNotify       notify;
  gpointer            notify_data;
  gboolean            preserve_calibration;
};

void nl_gamma_init       (NlGamma *gamma, const NlGammaClass *klass);
void nl_gamma_emit       (NlGamma *gamma);

/* Fill one channel: base (or a linear ramp when base is NULL) times factor. */
void nl_gamma_fill_ramp  (uint16_t *out, const uint16_t *base, guint size, double factor);
