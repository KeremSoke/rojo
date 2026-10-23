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

/* When it is night, and how far into a transition we are.
 *
 * Everything here is pure: given a time, a place and the settings it returns
 * the same answer, so it can be tested without a display.
 */

namespace Rojo {

public enum Mode {
    AUTOMATIC,   // from sunset to sunrise at the current location
    SCHEDULE,    // fixed times of day
    ALWAYS;      // night temperature all the time

    public static Mode parse (string nick) {
        switch (nick) {
        case "schedule": return SCHEDULE;
        case "always": return ALWAYS;
        default: return AUTOMATIC;
        }
    }

    public string to_nick () {
        switch (this) {
        case SCHEDULE: return "schedule";
        case ALWAYS: return "always";
        default: return "automatic";
        }
    }
}

namespace Sun {

public enum Event {
    NORMAL,
    ALWAYS_ABOVE,   // the sun doesn't drop below this altitude today
    ALWAYS_BELOW    // the sun doesn't reach this altitude today
}

/* Zenith angles, in degrees. */
public const double SUNRISE = 90.833;   // upper limb on the horizon, with refraction
public const double CIVIL = 96.0;       // end of civil twilight

private double deg2rad (double d) { return Math.PI * d / 180.0; }
private double rad2deg (double r) { return r * 180.0 / Math.PI; }

/* When the sun crosses `zenith` on the given UTC day, in hours after that
 * day's 00:00 UTC (so possibly below 0 or above 24).
 *
 * Formulas from https://gml.noaa.gov/grad/solcalc/calcdetails.html, as in
 * gnome-settings-daemon's gsd-night-light-common.c, with the zenith made a
 * parameter and the polar cases reported instead of returning NaN. */
public Event times (int year, int month, int day, double lat, double lon, double zenith,
                    out double rise, out double set) {
    rise = set = 0;
    var date = new DateTime.utc (year, month, day, 0, 0, 0);
    var epoch = new DateTime.utc (1900, 1, 1, 0, 0, 0);
    double date_as_number = (double) (date.difference (epoch) / TimeSpan.DAY) + 2;
    double julian_day = date_as_number + 2415018.5;
    double jc = (julian_day - 2451545) / 36525;
    double geom_mean_long = Math.fmod (280.46646 + jc * (36000.76983 + jc * 0.0003032), 360);
    double geom_mean_anom = 357.52911 + jc * (35999.05029 - 0.0001537 * jc);
    double eccent = 0.016708634 - jc * (0.000042037 + 0.0000001267 * jc);
    double eq_of_ctr = Math.sin (deg2rad (geom_mean_anom)) * (1.914602 - jc * (0.004817 + 0.000014 * jc)) +
                       Math.sin (deg2rad (2 * geom_mean_anom)) * (0.019993 - 0.000101 * jc) +
                       Math.sin (deg2rad (3 * geom_mean_anom)) * 0.000289;
    double true_long = geom_mean_long + eq_of_ctr;
    double app_long = true_long - 0.00569 - 0.00478 * Math.sin (deg2rad (125.04 - 1934.136 * jc));
    double mean_obliq = 23 + (26 + ((21.448 - jc * (46.815 + jc * (0.00059 - jc * 0.001813)))) / 60) / 60;
    double obliq_corr = mean_obliq + 0.00256 * Math.cos (deg2rad (125.04 - 1934.136 * jc));
    double declin = rad2deg (Math.asin (Math.sin (deg2rad (obliq_corr)) * Math.sin (deg2rad (app_long))));
    double var_y = Math.tan (deg2rad (obliq_corr / 2)) * Math.tan (deg2rad (obliq_corr / 2));
    double eq_of_time = 4 * rad2deg (var_y * Math.sin (2 * deg2rad (geom_mean_long)) -
                                     2 * eccent * Math.sin (deg2rad (geom_mean_anom)) +
                                     4 * eccent * var_y * Math.sin (deg2rad (geom_mean_anom)) *
                                         Math.cos (2 * deg2rad (geom_mean_long)) -
                                     0.5 * var_y * var_y * Math.sin (4 * deg2rad (geom_mean_long)) -
                                     1.25 * eccent * eccent * Math.sin (2 * deg2rad (geom_mean_anom)));
    double cos_ha = Math.cos (deg2rad (zenith)) / (Math.cos (deg2rad (lat)) * Math.cos (deg2rad (declin))) -
                    Math.tan (deg2rad (lat)) * Math.tan (deg2rad (declin));
    if (cos_ha > 1)
        return ALWAYS_BELOW;
    if (cos_ha < -1)
        return ALWAYS_ABOVE;
    double ha = rad2deg (Math.acos (cos_ha));
    double solar_noon = (720 - 4 * lon - eq_of_time) / 1440;
    rise = (solar_noon - ha * 4 / 1440) * 24;
    set = (solar_noon + ha * 4 / 1440) * 24;
    return NORMAL;
}

}

/* A change from day to night or back, as Unix times in seconds. */
public struct Transition {
    public int64 start;
    public int64 end;
    public bool to_night;

    public int64 duration { get { return end - start; } }
}

public class Schedule : Object {
    public const int64 MIN_TRANSITION = 60;

    public Mode mode = Mode.AUTOMATIC;
    public double latitude = double.NAN;
    public double longitude = double.NAN;
    public double from_hour = 20.0;     // SCHEDULE: night starts
    public double to_hour = 6.0;        // SCHEDULE: day starts
    public int64 transition = 1800;     // SCHEDULE: seconds; AUTOMATIC fallback
    public TimeZone tz = new TimeZone.utc ();

    public bool has_location {
        get { return !latitude.is_nan () && !longitude.is_nan () &&
                     latitude.abs () <= 90 && longitude.abs () <= 180; }
    }

    /* Whether the sun times are used; without a location AUTOMATIC falls back
     * to the fixed schedule, like GNOME does. */
    public bool uses_sun {
        get { return mode == Mode.AUTOMATIC && has_location; }
    }

    private struct DayInfo {
        Transition[] transitions;
        bool polar_night;
    }

    private DateTime at_hour (DateTime day, double hour) {
        // Whole seconds first: 6.0833… h is 06:05, not 06:04:59.99.
        int total = ((int) Math.round (hour * 3600)).clamp (0, 24 * 3600 - 1);
        return new DateTime (tz, day.get_year (), day.get_month (), day.get_day_of_month (),
                             total / 3600, total / 60 % 60, total % 60);
    }

    private int64 utc_hours (DateTime day, double hours) {
        var midnight = new DateTime.utc (day.get_year (), day.get_month (), day.get_day_of_month (), 0, 0, 0);
        return midnight.to_unix () + (int64) Math.round (hours * 3600);
    }

    private DayInfo day_info (DateTime day) {
        DayInfo info = { {}, false };
        if (uses_sun) {
            double rise, set, dawn, dusk;
            var ev = Sun.times (day.get_year (), day.get_month (), day.get_day_of_month (),
                                latitude, longitude, Sun.SUNRISE, out rise, out set);
            if (ev != Sun.Event.NORMAL) {
                info.polar_night = ev == Sun.Event.ALWAYS_BELOW;
                return info;
            }
            var civil = Sun.times (day.get_year (), day.get_month (), day.get_day_of_month (),
                                   latitude, longitude, Sun.CIVIL, out dawn, out dusk);
            int64 r = utc_hours (day, rise), s = utc_hours (day, set);
            // Warm up from sunset until civil dusk, and back from civil dawn to
            // sunrise, the way Redshift and older Plasma follow the sun. Where
            // twilight never ends (white nights) fall back to fixed lengths.
            int64 d = civil == Sun.Event.NORMAL ? utc_hours (day, dawn) : r - transition;
            int64 k = civil == Sun.Event.NORMAL ? utc_hours (day, dusk) : s + transition;
            info.transitions = {
                Transition () { start = d, end = int64.max (r, d + MIN_TRANSITION), to_night = false },
                Transition () { start = s, end = int64.max (k, s + MIN_TRANSITION), to_night = true }
            };
            return info;
        }

        // Fixed times: each transition starts at its time (as in Plasma), and
        // is shortened so the two never overlap.
        double gap = (to_hour - from_hour).abs ();
        gap = double.min (gap, 24 - gap) * 3600;
        int64 length = int64.max (int64.min (transition, (int64) (gap / 2)), MIN_TRANSITION);
        if (gap < 2 * MIN_TRANSITION)
            return info;   // equal times: no night at all
        var morning = at_hour (day, to_hour).to_unix ();
        var evening = at_hour (day, from_hour).to_unix ();
        info.transitions = {
            Transition () { start = morning, end = morning + length, to_night = false },
            Transition () { start = evening, end = evening + length, to_night = true }
        };
        return info;
    }

    /* The last transition that started at or before `now`, and the first one
     * after it. Returns false for either when there is none within two days
     * (polar day or night, or ALWAYS). `night` says whether it's night now,
     * counting a transition in progress as already being on its new side. */
    public void find (int64 now, out Transition prev, out bool has_prev,
                      out Transition next, out bool has_next, out bool night) {
        prev = next = Transition ();
        has_prev = has_next = false;
        night = mode == Mode.ALWAYS;
        if (mode == Mode.ALWAYS)
            return;

        var today = new DateTime.from_unix_utc (now).to_timezone (tz);
        bool polar_night_today = false;
        for (int offset = -2; offset <= 2; offset++) {
            var info = day_info (today.add_days (offset));
            if (offset == 0)
                polar_night_today = info.polar_night;
            foreach (var t in info.transitions) {
                if (t.start <= now) {
                    if (!has_prev || t.start > prev.start) {
                        prev = t;
                        has_prev = true;
                    }
                } else if (!has_next || t.start < next.start) {
                    next = t;
                    has_next = true;
                }
            }
        }
        night = has_prev ? prev.to_night : polar_night_today;
    }

    /* The scheduled temperature at `now`. */
    public double temperature_at (int64 now, double day_k, double night_k, out bool night) {
        Transition prev, next;
        bool has_prev, has_next;
        find (now, out prev, out has_prev, out next, out has_next, out night);
        if (has_prev && now < prev.end) {
            double progress = (double) (now - prev.start) / prev.duration;
            return prev.to_night ? ColorRamp.mix (day_k, night_k, progress)
                                 : ColorRamp.mix (night_k, day_k, progress);
        }
        return night ? night_k : day_k;
    }

    /* When the next night ends (its morning transition finishes), counting a
     * night in progress. Used for "until tomorrow". */
    public int64 next_morning_end (int64 now) {
        Transition prev, next;
        bool has_prev, has_next, night;
        find (now, out prev, out has_prev, out next, out has_next, out night);
        if (has_prev && !prev.to_night && now < prev.end)
            return prev.end;
        for (int i = 0; has_next && i < 4; i++) {
            if (!next.to_night)
                return next.end;
            find (next.start, out prev, out has_prev, out next, out has_next, out night);
        }
        // No transitions (ALWAYS, polar): tomorrow at the configured morning.
        var local = new DateTime.from_unix_utc (now).to_timezone (tz);
        var t = at_hour (local, to_hour);
        if (t.to_unix () <= now)
            t = at_hour (local.add_days (1), to_hour);
        return t.to_unix ();
    }

    /* Today's sunrise and sunset as local fractional hours, or -1. */
    public void sun_hours (int64 now, out double sunrise, out double sunset) {
        sunrise = sunset = -1;
        if (!has_location)
            return;
        var local = new DateTime.from_unix_utc (now).to_timezone (tz);
        double rise, set;
        if (Sun.times (local.get_year (), local.get_month (), local.get_day_of_month (),
                       latitude, longitude, Sun.SUNRISE, out rise, out set) != Sun.Event.NORMAL)
            return;
        sunrise = local_hour (utc_hours (local, rise));
        sunset = local_hour (utc_hours (local, set));
    }

    private double local_hour (int64 time) {
        var dt = new DateTime.from_unix_utc (time).to_timezone (tz);
        return dt.get_hour () + dt.get_minute () / 60.0 + dt.get_second () / 3600.0;
    }
}

}
