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

/* Where the user is, for sunset and sunrise.
 *
 * Sources, in the order "auto" tries them:
 *   - clock: the MATE clock applet's home location (the city marked current
 *     in its Locations tab), when it is in the system timezone, like the
 *     applet itself requires before using it;
 *   - geoclue: GeoClue2 over D-Bus. MATE has no GeoClue agent, so this needs
 *     the daemon to be allowed in geoclue's configuration (we install a
 *     conf.d snippet);
 *   - timezone: the coordinates tzdata gives for the system timezone, which
 *     is close enough for sun times in most places;
 *   - the last coordinates we had, kept in GSettings.
 */

namespace Rojo {

public struct Coordinates {
    public double latitude;
    public double longitude;

    public bool valid {
        get { return !latitude.is_nan () && !longitude.is_nan () &&
                     latitude.abs () <= 90 && longitude.abs () <= 180; }
    }

    public static Coordinates none () {
        return { double.NAN, double.NAN };
    }
}

/* Coordinates of tzdata zones, from zone1970.tab / zone.tab, with links
 * (old names like "US/Pacific") resolved through tzdata.zi. */
public class TimezoneDb : Object {
    private HashTable<string, Coordinates?> zones = new HashTable<string, Coordinates?> (str_hash, str_equal);
    private HashTable<string, string> links = new HashTable<string, string> (str_hash, str_equal);

    public TimezoneDb (string dir = "/usr/share/zoneinfo") {
        foreach (var name in new string[] { "zone.tab", "zone1970.tab" })
            load_tab (Path.build_filename (dir, name));
        load_links (Path.build_filename (dir, "tzdata.zi"));
    }

    /* ISO 6709: ±DDMM±DDDMM or ±DDMMSS±DDDMMSS. */
    public static Coordinates parse_iso6709 (string s) {
        try {
            var re = new Regex ("^([+-])(\\d{2})(\\d{2})(\\d{2})?([+-])(\\d{3})(\\d{2})(\\d{2})?$");
            MatchInfo m;
            if (!re.match (s, 0, out m))
                return Coordinates.none ();
            double lat = int.parse (m.fetch (2)) + int.parse (m.fetch (3)) / 60.0 +
                         int.parse (m.fetch (4) ?? "0") / 3600.0;
            double lon = int.parse (m.fetch (6)) + int.parse (m.fetch (7)) / 60.0 +
                         int.parse (m.fetch (8) ?? "0") / 3600.0;
            return { m.fetch (1) == "-" ? -lat : lat, m.fetch (5) == "-" ? -lon : lon };
        } catch (RegexError e) {
            return Coordinates.none ();
        }
    }

    private void load_tab (string path) {
        string contents;
        try {
            FileUtils.get_contents (path, out contents);
        } catch (FileError e) {
            return;
        }
        foreach (var line in contents.split ("\n")) {
            if (line.has_prefix ("#"))
                continue;
            var f = line.split ("\t");
            if (f.length < 3)
                continue;
            var c = parse_iso6709 (f[1]);
            if (c.valid)
                zones[f[2]] = c;
        }
    }

    private void load_links (string path) {
        string contents;
        try {
            FileUtils.get_contents (path, out contents);
        } catch (FileError e) {
            return;
        }
        foreach (var line in contents.split ("\n")) {
            if (!line.has_prefix ("L "))
                continue;
            var f = line.split (" ");
            if (f.length >= 3)
                links[f[2]] = f[1];
        }
    }

    public Coordinates lookup (string tz_id) {
        string id = tz_id;
        for (int i = 0; i < 4 && !(id in zones) && id in links; i++)
            id = links[id];
        return zones[id] ?? Coordinates.none ();
    }
}

/* The MATE clock applet's home location. */
public class ClockAppletLocation : Object {
    private const string OBJECT_SCHEMA = "org.mate.panel.object";
    private const string CLOCK_SCHEMA = "org.mate.panel.applet.clock";

    public signal void changed ();

    public Coordinates coordinates { get; private set; default = Coordinates.none (); }
    public string city { get; private set; default = ""; }

    private Settings? panel;
    private GenericArray<Settings> watched = new GenericArray<Settings> ();
    private string tz_id = "";

    public ClockAppletLocation () {
        var source = SettingsSchemaSource.get_default ();
        if (source == null || source.lookup ("org.mate.panel", true) == null ||
            source.lookup (OBJECT_SCHEMA, true) == null || source.lookup (CLOCK_SCHEMA, true) == null) {
            debug ("mate-panel schemas not installed; not using the clock applet");
            return;
        }
        panel = new Settings ("org.mate.panel");
        panel.changed["object-id-list"].connect (() => rescan ());
    }

    public void update_timezone (string tz) {
        tz_id = tz;
        rescan ();
    }

    public struct City {
        public string name;
        public string timezone;
        public Coordinates coordinates;
        public bool current;
    }

    /* Parse one entry of the applet's "cities" key, e.g.
     * <location name="" city="Vancouver" timezone="America/Vancouver"
     *  latitude="49.18" longitude="-123.16" code="CYVR" current="true"/> */
    public static bool parse_city (string xml, out City city) {
        City c = { "", "", Coordinates.none (), false };
        city = c;
        if (!xml.strip ().has_prefix ("<location "))
            return false;
        double lat = double.NAN, lon = double.NAN;
        string name = "", city_name = "";
        try {
            var re = new Regex ("([a-z_]+)=\"([^\"]*)\"");
            MatchInfo m;
            for (re.match (xml, 0, out m); m.matches (); m.next ()) {
                var value = unescape (m.fetch (2));
                switch (m.fetch (1)) {
                case "name": name = value; break;
                case "city": city_name = value; break;
                case "timezone": c.timezone = value; break;
                case "latitude": lat = double.parse (value); break;
                case "longitude": lon = double.parse (value); break;
                case "current": c.current = value == "true"; break;
                }
            }
        } catch (RegexError e) {
            return false;
        }
        // Older configurations only have a name, which was the city.
        c.name = city_name != "" ? city_name : name;
        c.coordinates = { lat, lon };
        city = c;
        return c.coordinates.valid && c.timezone != "";
    }

    private static string unescape (string s) {
        return s.replace ("&quot;", "\"").replace ("&apos;", "'").replace ("&lt;", "<")
                .replace ("&gt;", ">").replace ("&amp;", "&");
    }

    private void rescan () {
        if (panel == null)
            return;
        foreach (var s in watched)
            SignalHandler.disconnect_matched (s, SignalMatchType.DATA, 0, 0, null, null, this);
        watched = new GenericArray<Settings> ();

        Coordinates found = Coordinates.none ();
        string found_city = "";
        foreach (var id in panel.get_strv ("object-id-list")) {
            var path = "/org/mate/panel/objects/%s/".printf (id);
            var obj = new Settings.with_path (OBJECT_SCHEMA, path);
            if (!obj.get_string ("applet-iid").has_suffix ("::ClockApplet"))
                continue;
            var prefs = new Settings.with_path (CLOCK_SCHEMA, path + "prefs/");
            prefs.changed["cities"].connect (on_cities_changed);
            watched.add (prefs);
            foreach (var entry in prefs.get_strv ("cities")) {
                City c;
                if (parse_city (entry, out c) && c.current && c.timezone == tz_id && !found.valid) {
                    found = c.coordinates;
                    found_city = c.name;
                }
            }
        }

        if (found.latitude != coordinates.latitude || found.longitude != coordinates.longitude ||
            found_city != city) {
            coordinates = found;
            city = found_city;
            changed ();
        }
    }

    private void on_cities_changed () {
        rescan ();
    }
}

[DBus (name = "org.freedesktop.GeoClue2.Manager")]
private interface GeoClueManager : Object {
    public abstract async ObjectPath get_client () throws Error;
}

[DBus (name = "org.freedesktop.GeoClue2.Client")]
private interface GeoClueClient : Object {
    public abstract string desktop_id { owned get; set; }
    public abstract uint requested_accuracy_level { get; set; }
    public abstract uint distance_threshold { get; set; }
    public abstract async void start () throws Error;
    public abstract async void stop () throws Error;
    public signal void location_updated (ObjectPath old_path, ObjectPath new_path);
}

[DBus (name = "org.freedesktop.GeoClue2.Location")]
private interface GeoClueLocation : Object {
    public abstract double latitude { get; }
    public abstract double longitude { get; }
}

/* GeoClue2, spoken over D-Bus so we don't need libgeoclue. */
public class GeoClueSource : Object {
    public const string DESKTOP_ID = "rojo";
    private const uint ACCURACY_CITY = 4;

    public signal void changed ();

    public Coordinates coordinates { get; private set; default = Coordinates.none (); }
    public bool failed { get; private set; }

    private GeoClueClient? client;
    private bool started = false;

    public void start () {
        if (started)
            return;
        started = true;
        failed = false;
        start_async.begin ();
    }

    public void stop () {
        if (!started)
            return;
        started = false;
        if (client != null)
            client.stop.begin ();
        client = null;
    }

    private async void start_async () {
        try {
            GeoClueManager manager = yield Bus.get_proxy (BusType.SYSTEM, "org.freedesktop.GeoClue2",
                                                         "/org/freedesktop/GeoClue2/Manager");
            var path = yield manager.get_client ();
            client = yield Bus.get_proxy (BusType.SYSTEM, "org.freedesktop.GeoClue2", path);
            client.desktop_id = DESKTOP_ID;
            client.requested_accuracy_level = ACCURACY_CITY;
            client.distance_threshold = 10000;
            client.location_updated.connect ((old_path, new_path) => read_location.begin (new_path));
            yield client.start ();
            debug ("GeoClue started");
        } catch (Error e) {
            // Usually "not allowed": no agent and not listed in geoclue.conf.
            message ("GeoClue unavailable: %s", e.message);
            client = null;
            failed = true;
            changed ();
        }
    }

    private async void read_location (ObjectPath path) {
        try {
            GeoClueLocation loc = yield Bus.get_proxy (BusType.SYSTEM, "org.freedesktop.GeoClue2", path);
            coordinates = { loc.latitude, loc.longitude };
            debug ("GeoClue location %.3f, %.3f", coordinates.latitude, coordinates.longitude);
            changed ();
        } catch (Error e) {
            warning ("Cannot read GeoClue location: %s", e.message);
        }
    }
}

public class LocationMonitor : Object {
    public signal void changed ();

    public Coordinates coordinates { get; private set; default = Coordinates.none (); }
    /* Which source the coordinates came from: manual, clock, geoclue,
     * timezone, cache or none. */
    public string source { get; private set; default = "none"; }
    /* Something to show: a city, a timezone, or empty. */
    public string name { get; private set; default = ""; }

    private Settings settings;
    private ClockAppletLocation clock = new ClockAppletLocation ();
    private GeoClueSource geoclue = new GeoClueSource ();
    private TimezoneDb? tzdb;
    private string tz_id = "";

    public LocationMonitor (Settings settings, string tz_id) {
        this.settings = settings;
        this.tz_id = tz_id;
        clock.update_timezone (tz_id);
        clock.changed.connect (resolve);
        geoclue.changed.connect (resolve);
        settings.changed.connect ((key) => {
            if (key == "location-source" || key == "manual-latitude" || key == "manual-longitude")
                resolve ();
        });
        resolve ();
    }

    public void update_timezone (string tz) {
        if (tz == tz_id)
            return;
        tz_id = tz;
        clock.update_timezone (tz);   // emits changed → resolve() if it matters
        resolve ();
    }

    private Coordinates from_timezone () {
        if (tzdb == null)
            tzdb = new TimezoneDb ();
        return tzdb.lookup (tz_id);
    }

    private Coordinates cached () {
        double lat, lon;
        settings.get ("last-coordinates", "(dd)", out lat, out lon);
        return { lat, lon };
    }

    private bool try_source (string which) {
        Coordinates c = Coordinates.none ();
        string label = "";
        switch (which) {
        case "manual":
            c = { settings.get_double ("manual-latitude"), settings.get_double ("manual-longitude") };
            break;
        case "clock":
            c = clock.coordinates;
            label = clock.city;
            break;
        case "geoclue":
            geoclue.start ();
            c = geoclue.coordinates;
            break;
        case "timezone":
            c = from_timezone ();
            label = tz_id;
            break;
        case "cache":
            c = cached ();
            break;
        }
        if (!c.valid)
            return false;
        bool moved = c.latitude != coordinates.latitude || c.longitude != coordinates.longitude;
        coordinates = c;
        name = label;
        source = which;
        if (which != "cache" && which != "manual") {
            var old = cached ();
            if (!old.valid || (old.latitude - c.latitude).abs () > 0.01 ||
                (old.longitude - c.longitude).abs () > 0.01)
                settings.set ("last-coordinates", "(dd)", c.latitude, c.longitude);
        }
        if (moved)
            changed ();
        return true;
    }

    private void resolve () {
        string[] order;
        switch (settings.get_string ("location-source")) {
        case "manual": order = { "manual" }; break;
        case "clock": order = { "clock", "cache", "timezone" }; break;
        case "geoclue": order = { "geoclue", "cache", "timezone" }; break;
        case "timezone": order = { "timezone", "cache" }; break;
        default:
            // The clock applet's home city is what the user told MATE; GeoClue
            // is only asked when there is none. While it hasn't answered we
            // use the timezone, which is better than a stale cache when the
            // user has travelled.
            order = { "clock", "geoclue", "timezone", "cache" };
            break;
        }
        if (!("geoclue" in order) || (clock.coordinates.valid && order[0] == "clock"))
            geoclue.stop ();
        foreach (var which in order) {
            if (try_source (which))
                return;
        }
        if (coordinates.valid) {
            coordinates = Coordinates.none ();
            source = "none";
            name = "";
            changed ();
        }
    }
}

}
