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

using Rojo;

TimeZone zone (string id) {
    try {
        return new TimeZone.identifier (id);
    } catch (Error e) {
        error ("%s", e.message);
    }
}

int64 at (string tz, int y, int mo, int d, int h, int mi) {
    return new DateTime (zone (tz), y, mo, d, h, mi, 0).to_unix ();
}

void assert_near (double value, double expected, double tolerance, string what) {
    if ((value - expected).abs () > tolerance)
        error ("%s: got %f, expected %f ± %f", what, value, expected, tolerance);
}

Schedule fixed_schedule () {
    var s = new Schedule ();
    s.mode = Mode.SCHEDULE;
    s.tz = zone ("Europe/Istanbul");
    s.from_hour = 20;
    s.to_hour = 6;
    s.transition = 1800;
    return s;
}

void test_colorramp () {
    double r, g, b;
    ColorRamp.factors (6500, out r, out g, out b);
    assert (r == 1 && g == 1 && b == 1);
    ColorRamp.factors (1000, out r, out g, out b);
    assert_near (g, 0.18172716, 1e-6, "green at 1000K");
    assert (r == 1 && b == 0);
    ColorRamp.factors (4050, out r, out g, out b);
    double r1, g1, b1, r2, g2, b2;
    ColorRamp.factors (4000, out r1, out g1, out b1);
    ColorRamp.factors (4100, out r2, out g2, out b2);
    assert_near (b, (b1 + b2) / 2, 1e-9, "interpolated blue");
    ColorRamp.factors (10000, out r, out g, out b);
    assert (r < 1 && b == 1);

    assert_near (ColorRamp.mix (6500, 3500, 0), 6500, 1e-6, "mix start");
    assert_near (ColorRamp.mix (6500, 3500, 1), 3500, 1e-6, "mix end");
    // Halfway in mired is warmer-biased compared to halfway in Kelvin.
    assert (ColorRamp.mix (6500, 3500, 0.5) < 5000);
}

void test_sun_times () {
    var s = new Schedule ();
    s.mode = Mode.AUTOMATIC;
    double rise, set;

    // Vancouver, summer solstice: about 05:07 and 21:21 PDT.
    s.tz = zone ("America/Vancouver");
    s.latitude = 49.28;
    s.longitude = -123.12;
    s.sun_hours (at ("America/Vancouver", 2026, 6, 21, 12, 0), out rise, out set);
    assert_near (rise, 5 + 7 / 60.0, 0.1, "Vancouver sunrise");
    assert_near (set, 21 + 21 / 60.0, 0.1, "Vancouver sunset");

    // Istanbul, winter solstice: about 08:26 and 17:38 (+03, permanent since 2016).
    s.tz = zone ("Europe/Istanbul");
    s.latitude = 41.01;
    s.longitude = 28.98;
    s.sun_hours (at ("Europe/Istanbul", 2026, 12, 21, 12, 0), out rise, out set);
    assert_near (rise, 8 + 26 / 60.0, 0.1, "Istanbul sunrise");
    assert_near (set, 17 + 38 / 60.0, 0.1, "Istanbul sunset");

    // The evening transition starts at sunset and ends at civil dusk.
    Transition prev, next;
    bool has_prev, has_next, night;
    s.find (at ("Europe/Istanbul", 2026, 12, 21, 17, 50), out prev, out has_prev,
            out next, out has_next, out night);
    assert (has_prev && prev.to_night && night);
    assert (prev.duration > 20 * 60 && prev.duration < 40 * 60);
    assert (has_next && !next.to_night);
}

void test_polar () {
    var s = new Schedule ();
    s.mode = Mode.AUTOMATIC;
    s.tz = zone ("Europe/Oslo");
    s.latitude = 69.65;     // Tromsø
    s.longitude = 18.96;
    bool night;
    double k = s.temperature_at (at ("Europe/Oslo", 2026, 12, 21, 12, 0), 6500, 3500, out night);
    assert (night);
    assert_near (k, 3500, 0.5, "polar night");
    k = s.temperature_at (at ("Europe/Oslo", 2026, 6, 21, 0, 30), 6500, 3500, out night);
    assert (!night);
    assert_near (k, 6500, 0.5, "midnight sun");
    double rise, set;
    s.sun_hours (at ("Europe/Oslo", 2026, 12, 21, 12, 0), out rise, out set);
    assert (rise == -1 && set == -1);
}

void test_fixed_schedule () {
    var s = fixed_schedule ();
    bool night;
    var tz = "Europe/Istanbul";
    assert_near (s.temperature_at (at (tz, 2026, 3, 10, 19, 59), 6500, 3500, out night), 6500, 0.5, "before");
    assert (!night);
    double mid = s.temperature_at (at (tz, 2026, 3, 10, 20, 15), 6500, 3500, out night);
    assert (night);
    assert_near (mid, ColorRamp.mix (6500, 3500, 0.5), 1, "halfway");
    assert_near (s.temperature_at (at (tz, 2026, 3, 10, 23, 0), 6500, 3500, out night), 3500, 0.5, "night");
    assert_near (s.temperature_at (at (tz, 2026, 3, 11, 3, 0), 6500, 3500, out night), 3500, 0.5, "after midnight");
    assert (night);
    double morning = s.temperature_at (at (tz, 2026, 3, 11, 6, 10), 6500, 3500, out night);
    assert (morning > 3500 && morning < 6500 && !night);
    assert_near (s.temperature_at (at (tz, 2026, 3, 11, 7, 0), 6500, 3500, out night), 6500, 0.5, "day");

    // The transition is shortened so day and night don't overlap.
    s.from_hour = 6.25;
    bool has_prev, has_next;
    Transition prev, next;
    s.find (at (tz, 2026, 3, 11, 6, 1), out prev, out has_prev, out next, out has_next, out night);
    assert (has_prev && prev.duration <= 450);

    // Equal times: never night.
    s.from_hour = 6;
    assert_near (s.temperature_at (at (tz, 2026, 3, 11, 23, 0), 6500, 3500, out night), 6500, 0.5, "no night");
}

void test_dst () {
    var s = fixed_schedule ();
    s.tz = zone ("Europe/Berlin");
    s.to_hour = 2.5;   // doesn't exist on the night clocks go forward
    bool night;
    double k = s.temperature_at (at ("Europe/Berlin", 2026, 3, 29, 4, 0), 6500, 3500, out night);
    assert (!night);
    assert_near (k, 6500, 0.5, "after a skipped hour");
}

void test_until_tomorrow () {
    var s = fixed_schedule ();
    var tz = "Europe/Istanbul";
    var expected = at (tz, 2026, 3, 11, 6, 30);
    assert (s.next_morning_end (at (tz, 2026, 3, 10, 23, 0)) == expected);
    assert (s.next_morning_end (at (tz, 2026, 3, 10, 12, 0)) == expected);
    assert (s.next_morning_end (at (tz, 2026, 3, 11, 6, 10)) == expected);

    s.mode = Mode.ALWAYS;
    assert (s.next_morning_end (at (tz, 2026, 3, 10, 23, 0)) == at (tz, 2026, 3, 11, 6, 0));
}

void test_timezone_db () {
    var c = TimezoneDb.parse_iso6709 ("+4916-12307");
    assert_near (c.latitude, 49 + 16 / 60.0, 1e-9, "lat");
    assert_near (c.longitude, -(123 + 7 / 60.0), 1e-9, "lon");
    c = TimezoneDb.parse_iso6709 ("-332052+1510652");
    assert_near (c.latitude, -(33 + 20 / 60.0 + 52 / 3600.0), 1e-9, "lat with seconds");
    assert (!TimezoneDb.parse_iso6709 ("garbage").valid);

    if (!FileUtils.test ("/usr/share/zoneinfo/zone1970.tab", FileTest.EXISTS)) {
        Test.skip ("no tzdata");
        return;
    }
    var db = new TimezoneDb ();
    c = db.lookup ("Europe/Istanbul");
    assert_near (c.latitude, 41.0, 0.1, "Istanbul");
    if (FileUtils.test ("/usr/share/zoneinfo/tzdata.zi", FileTest.EXISTS)) {
        c = db.lookup ("US/Pacific");
        assert_near (c.longitude, -118.2, 0.2, "US/Pacific via link");
    }
    assert (!db.lookup ("Nowhere/Nothing").valid);
}

void test_clock_city () {
    ClockAppletLocation.City city;
    assert (ClockAppletLocation.parse_city (
        "<location name=\"\" city=\"Vancouver\" timezone=\"America/Vancouver\" " +
        "latitude=\"49.183334\" longitude=\"-123.166664\" code=\"CYVR\" current=\"true\"/>", out city));
    assert (city.name == "Vancouver" && city.timezone == "America/Vancouver" && city.current);
    assert_near (city.coordinates.longitude, -123.166664, 1e-6, "clock longitude");

    assert (ClockAppletLocation.parse_city (
        "<location name=\"S&amp;P\" timezone=\"Europe/Paris\" latitude=\"49.0\" longitude=\"2.5\"/>",
        out city));
    assert (city.name == "S&P" && !city.current);

    assert (!ClockAppletLocation.parse_city ("<location name=\"x\" latitude=\"1\" longitude=\"2\"/>", out city));
    assert (!ClockAppletLocation.parse_city ("not xml", out city));
}

int main (string[] args) {
    Test.init (ref args);
    Test.add_func ("/colorramp", test_colorramp);
    Test.add_func ("/sun/times", test_sun_times);
    Test.add_func ("/sun/polar", test_polar);
    Test.add_func ("/schedule/fixed", test_fixed_schedule);
    Test.add_func ("/schedule/dst", test_dst);
    Test.add_func ("/schedule/until-tomorrow", test_until_tomorrow);
    Test.add_func ("/location/timezone-db", test_timezone_db);
    Test.add_func ("/location/clock-city", test_clock_city);
    return Test.run ();
}
