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

/* Notices when wall-clock time stops matching what our timers assume.
 *
 * GLib timers run on the monotonic clock, which doesn't advance during
 * suspend and ignores changes to the system time, so a timer set for "the
 * start of the evening transition" can fire hours late. Like KWin's clock
 * skew notifier we compare the two clocks, and also listen to logind for
 * resume (when drivers may also have reset the gamma ramps) and watch
 * /etc/localtime for timezone changes.
 */

namespace Rojo {

[DBus (name = "org.freedesktop.login1.Manager")]
private interface Login1 : Object {
    public signal void prepare_for_sleep (bool start);
}

public class ClockMonitor : Object {
    private const uint CHECK_INTERVAL_S = 5;
    private const int64 MAX_SKEW_US = 2 * TimeSpan.SECOND;

    /* The wall clock moved relative to the monotonic clock. */
    public signal void time_changed ();
    /* The system woke up from suspend or hibernation. */
    public signal void resumed ();

    public TimeZone tz { get; private set; }
    public string tz_id { get; private set; default = ""; }

    private int64 offset;
    private Login1? login1;
    private FileMonitor? localtime_monitor;
    private uint tz_reload_id = 0;

    public ClockMonitor () {
        load_timezone ();
        offset = get_real_time () - get_monotonic_time ();
        Timeout.add_seconds (CHECK_INTERVAL_S, () => {
            check_skew ();
            return Source.CONTINUE;
        });

        Bus.get_proxy.begin<Login1> (BusType.SYSTEM, "org.freedesktop.login1",
                                     "/org/freedesktop/login1", DBusProxyFlags.DO_NOT_LOAD_PROPERTIES,
                                     null, (obj, res) => {
            try {
                login1 = Bus.get_proxy.end (res);
                login1.prepare_for_sleep.connect ((start) => {
                    if (!start) {
                        debug ("Resumed from sleep");
                        offset = get_real_time () - get_monotonic_time ();
                        resumed ();
                    }
                });
            } catch (Error e) {
                debug ("No logind, resume won't be noticed directly: %s", e.message);
            }
        });

        try {
            // /etc/localtime is usually a symlink that gets replaced, so watch
            // the name rather than its target.
            localtime_monitor = File.new_for_path ("/etc/localtime").monitor_file (
                FileMonitorFlags.WATCH_MOVES | FileMonitorFlags.WATCH_HARD_LINKS);
            localtime_monitor.changed.connect (() => {
                if (tz_reload_id != 0)
                    Source.remove (tz_reload_id);
                tz_reload_id = Timeout.add (500, () => {
                    tz_reload_id = 0;
                    var old = tz_id;
                    load_timezone ();
                    if (tz_id != old) {
                        message ("Timezone changed to %s", tz_id);
                        time_changed ();
                    }
                    return Source.REMOVE;
                });
            });
        } catch (Error e) {
            debug ("Cannot watch /etc/localtime: %s", e.message);
        }
    }

    private void check_skew () {
        var now = get_real_time () - get_monotonic_time ();
        if ((now - offset).abs () > MAX_SKEW_US) {
            debug ("Wall clock moved by %.1f s", (now - offset) / 1e6);
            offset = now;
            time_changed ();
        }
    }

    /* The system timezone's identifier. GLib caches the local timezone for
     * the life of the process, so read it ourselves to notice changes. */
    public static string read_tz_id () {
        var env = Environment.get_variable ("TZ");
        if (env != null && env != "" && !env.has_prefix (":/"))
            return env.has_prefix (":") ? env.substring (1) : env;
        try {
            var target = FileUtils.read_link ("/etc/localtime");
            int i = target.index_of ("zoneinfo/");
            if (i >= 0)
                return target.substring (i + "zoneinfo/".length);
        } catch (FileError e) {}
        try {
            string contents;
            FileUtils.get_contents ("/etc/timezone", out contents);
            return contents.strip ();
        } catch (FileError e) {}
        return "";
    }

    private void load_timezone () {
        tz_id = read_tz_id ();
        TimeZone? zone = null;
        if (tz_id != "") {
            try {
                zone = new TimeZone.identifier (tz_id);
            } catch (Error e) {
                debug ("Unknown timezone %s", tz_id);
            }
        }
        tz = zone ?? new TimeZone.local ();
    }

    public int64 now () {
        return get_real_time () / TimeSpan.SECOND;
    }
}

}
