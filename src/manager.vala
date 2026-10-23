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

/* Decides the screen color temperature and moves the screen towards it.
 *
 * What is wanted comes from, in order of precedence:
 *   preview (a settings dialog dragging a slider, times out after 15 s)
 *   inhibit (someone asked for true colors, e.g. a photo editor or a game)
 *   activate/deactivate overrides (manual, or until a time; "until tomorrow")
 *   the mode: the sun's schedule, fixed times, or always on.
 *
 * How it gets there: changes along the schedule are applied in small steps
 * every second, so a 40-minute dusk is one long smooth fade. Anything else
 * that changes the wanted temperature (enabling, overrides, inhibit,
 * settings, waking up in a different period) is animated at the display's
 * frame rate over a couple of seconds. Both are interpolated in mired so the
 * fade looks even.
 */

namespace Rojo {

public class Manager : Object {
    private const uint FRAME_MS = 16;
    private const int64 QUICK_ADJUST_US = 2500 * TimeSpan.MILLISECOND;
    private const int64 PREVIEW_ADJUST_US = 250 * TimeSpan.MILLISECOND;
    private const int64 SHUTDOWN_FADE_US = 600 * TimeSpan.MILLISECOND;
    private const uint PREVIEW_TIMEOUT_S = 15;
    private const uint VERIFY_INTERVAL_S = 2;
    private const uint TRANSITION_TICK_MS = 1000;
    private const uint IDLE_TICK_MS = 60000;
    /* Smaller changes are applied directly; larger ones are animated. */
    private const double JUMP_K = 30;
    /* Like KWin, an override that ends within a minute counts as ended. */
    private const int64 OVERRIDE_SLACK = 60;

    public Settings settings { get; construct; }

    /* ---- state, mirrored on D-Bus ---- */

    public bool available { get; private set; }
    public string backend_name { get; private set; default = "none"; }
    /* "ok"; "busy" when some output refused us (another program holds its
     * gamma, or it can't adjust gamma at all); otherwise the error that
     * made the backend unavailable. */
    public string backend_status { get; private set; default = ""; }

    public bool enabled { get; private set; }
    public string mode { get; private set; default = "automatic"; }
    /* Whether Night Light is in charge at all (enabled or activated by an
     * override, and not inhibited). */
    public bool running { get; private set; }
    public bool daylight { get; private set; default = true; }
    public bool inhibited { get; private set; }
    public string[] inhibitors { get; private set; default = {}; }
    public bool previewing { get; private set; }

    public uint current_temperature { get; private set; default = ColorRamp.NEUTRAL_TEMPERATURE; }
    public uint target_temperature { get; private set; default = ColorRamp.NEUTRAL_TEMPERATURE; }

    /* NaN when unknown (set in the constructor; a NaN default would be
     * rejected by GParamSpec). */
    public double latitude { get; private set; }
    public double longitude { get; private set; }
    public string location_source { get; private set; default = "none"; }
    public string location_name { get; private set; default = ""; }
    public double sunrise { get; private set; default = -1; }
    public double sunset { get; private set; default = -1; }

    public uint64 previous_transition_start { get; private set; }
    public uint previous_transition_duration { get; private set; }
    public uint64 next_transition_start { get; private set; }
    public uint next_transition_duration { get; private set; }

    public uint64 activated_until { get; private set; }
    public bool activated_manual { get; private set; }
    public uint64 deactivated_until { get; private set; }
    public bool deactivated_manual { get; private set; }

    /* ---- internals ---- */

    private ClockMonitor clock;
    private LocationMonitor location;
    private GammaBackend? backend;
    private Schedule schedule = new Schedule ();
    private string? forced_backend;

    private double day_temperature = ColorRamp.NEUTRAL_TEMPERATURE;
    private double night_temperature = 4000;
    private bool smooth = true;

    /* What the screen shows now, unrounded. We start from neutral, so a
     * login at night fades in instead of snapping. */
    private double shown = ColorRamp.NEUTRAL_TEMPERATURE;
    private double wanted = ColorRamp.NEUTRAL_TEMPERATURE;

    private uint anim_id = 0;
    private double anim_from;
    private int64 anim_start;
    private int64 anim_length;

    private uint tick_id = 0;
    private uint verify_id = 0;
    private uint preview_timeout_id = 0;
    private double preview_temperature;

    private class Inhibitor {
        public uint cookie;
        public string owner;
        public string reason;
        public uint watch_id;
    }
    private HashTable<uint, Inhibitor> inhibitor_table = new HashTable<uint, Inhibitor> (direct_hash, direct_equal);
    private uint next_cookie = 1;
    private uint toggle_cookie = 0;

    private KeyFile state = new KeyFile ();
    private bool shutting_down = false;

    public Manager (Settings settings, string? forced_backend = null) {
        Object (settings: settings);
        this.forced_backend = forced_backend;
        latitude = longitude = double.NAN;

        clock = new ClockMonitor ();
        clock.time_changed.connect (() => {
            location.update_timezone (clock.tz_id);
            evaluate ();
        });
        clock.resumed.connect (() => {
            // Drivers may have reset the ramps while asleep; show the right
            // value at once rather than fading from what we had before.
            if (backend != null)
                backend.force_reapply ();
            evaluate (true);
        });

        location = new LocationMonitor (settings, clock.tz_id);
        location.changed.connect (() => evaluate ());

        settings.changed.connect (on_settings_changed);
        load_settings ();
        load_state ();
        connect_backend ();
        evaluate ();
    }

    /* ---- settings and persistent state ---- */

    private void load_settings () {
        enabled = settings.get_boolean ("enabled");
        mode = settings.get_string ("mode");
        night_temperature = ColorRamp.clamp_temperature (settings.get_uint ("night-temperature"));
        day_temperature = ColorRamp.clamp_temperature (settings.get_uint ("day-temperature"));
        smooth = settings.get_boolean ("smooth-transitions");
        schedule.mode = Mode.parse (mode);
        schedule.from_hour = settings.get_double ("schedule-from").clamp (0, 23.999);
        schedule.to_hour = settings.get_double ("schedule-to").clamp (0, 23.999);
        schedule.transition = settings.get_uint ("transition-duration") * 60;
        if (backend != null)
            backend.set_preserve_calibration (settings.get_boolean ("preserve-calibration"));
    }

    private void on_settings_changed (string key) {
        if (key == "last-coordinates")
            return;
        load_settings ();
        evaluate ();
    }

    private static string state_path () {
        return Path.build_filename (Environment.get_user_state_dir (), "rojo", "state.ini");
    }

    /* Overrides survive restarts and re-logins, like KWin's. */
    private void load_state () {
        try {
            state.load_from_file (state_path (), KeyFileFlags.NONE);
            activated_until = state.get_uint64 ("override", "activated-until");
            activated_manual = state.get_boolean ("override", "activated-manual");
            deactivated_until = state.get_uint64 ("override", "deactivated-until");
            deactivated_manual = state.get_boolean ("override", "deactivated-manual");
        } catch (Error e) {}
    }

    private void save_state () {
        state.set_uint64 ("override", "activated-until", activated_until);
        state.set_boolean ("override", "activated-manual", activated_manual);
        state.set_uint64 ("override", "deactivated-until", deactivated_until);
        state.set_boolean ("override", "deactivated-manual", deactivated_manual);
        try {
            DirUtils.create_with_parents (Path.get_dirname (state_path ()), 0700);
            state.save_to_file (state_path ());
        } catch (Error e) {
            warning ("Cannot save state: %s", e.message);
        }
    }

    /* ---- backend ---- */

    private void connect_backend () {
        string error;
        backend = GammaBackend.create (forced_backend, out error);
        if (backend == null) {
            warning ("Night Light is unavailable: %s", error);
            available = false;
            backend_name = "none";
            backend_status = error;
            return;
        }
        message ("Using the %s backend with %u output(s)", backend.name, backend.n_outputs);
        available = true;
        backend_name = backend.name;
        backend.set_preserve_calibration (settings.get_boolean ("preserve-calibration"));
        backend.outputs_changed.connect (() => {
            update_backend_status ();
            push (shown);
        });
        backend.lost.connect (() => {
            backend = null;
            available = false;
            backend_status = "display connection lost";
            lost ();
        });
        update_backend_status ();
    }

    /* The display server went away; the session is ending. */
    public signal void lost ();

    private void update_backend_status () {
        if (backend == null)
            return;
        backend_status = backend.n_busy > 0 ? "busy" : "ok";
    }

    private void push (double temperature) {
        if (backend == null)
            return;
        backend.show (temperature);
        update_backend_status ();
        if (ColorRamp.is_neutral (temperature)) {
            if (verify_id != 0)
                Source.remove (verify_id);
            verify_id = 0;
        } else if (verify_id == 0) {
            verify_id = Timeout.add_seconds (VERIFY_INTERVAL_S, () => {
                if (backend != null && !backend.verify ())
                    message ("Gamma ramps were changed by another program; restored them");
                update_backend_status ();
                return Source.CONTINUE;
            });
        }
    }

    private void set_shown (double temperature) {
        shown = temperature;
        current_temperature = (uint) Math.round (temperature);
        push (temperature);
    }

    /* ---- animation ---- */

    private void stop_animation () {
        if (anim_id != 0)
            Source.remove (anim_id);
        anim_id = 0;
    }

    private void animate (int64 length) {
        anim_from = shown;
        anim_start = get_monotonic_time ();
        anim_length = length;
        if (anim_id != 0)
            return;
        anim_id = Timeout.add (FRAME_MS, () => {
            double t = (double) (get_monotonic_time () - anim_start) / anim_length;
            if (t >= 1) {
                anim_id = 0;
                set_shown (wanted);
                schedule_tick ();
                return Source.REMOVE;
            }
            // Smoothstep: no sudden start or stop.
            double eased = t * t * (3 - 2 * t);
            set_shown (ColorRamp.mix (anim_from, wanted, eased));
            return Source.CONTINUE;
        });
    }

    /* Head for `temperature`, animating if it's a visible jump. */
    private void go_to (double temperature, bool instant) {
        bool retarget = (temperature - wanted).abs () > JUMP_K;
        wanted = temperature;
        target_temperature = (uint) Math.round (temperature);
        if (instant || !smooth) {
            stop_animation ();
            set_shown (temperature);
        } else if (anim_id != 0) {
            if (retarget)
                animate (previewing ? PREVIEW_ADJUST_US : QUICK_ADJUST_US);
        } else if ((temperature - shown).abs () > JUMP_K) {
            animate (previewing ? PREVIEW_ADJUST_US : QUICK_ADJUST_US);
        } else if (Math.round (temperature) != Math.round (shown) || ColorRamp.is_neutral (temperature) != ColorRamp.is_neutral (shown)) {
            set_shown (temperature);
        }
    }

    /* ---- policy ---- */

    private bool temporarily_activated (int64 now) {
        return activated_manual || (activated_until > 0 && (int64) activated_until - now > OVERRIDE_SLACK);
    }

    private bool temporarily_deactivated (int64 now) {
        return deactivated_manual || (deactivated_until > 0 && (int64) deactivated_until - now > OVERRIDE_SLACK);
    }

    private void expire_overrides (int64 now) {
        bool changed = false;
        if (activated_until > 0 && (int64) activated_until - now <= OVERRIDE_SLACK) {
            activated_until = 0;
            changed = true;
        }
        if (deactivated_until > 0 && (int64) deactivated_until - now <= OVERRIDE_SLACK) {
            deactivated_until = 0;
            changed = true;
        }
        if (changed) {
            debug ("Override expired");
            save_state ();
        }
    }

    private void update_location () {
        var c = location.coordinates;
        schedule.latitude = c.latitude;
        schedule.longitude = c.longitude;
        if (latitude != c.latitude && !(latitude.is_nan () && c.latitude.is_nan ()))
            latitude = c.latitude;
        if (longitude != c.longitude && !(longitude.is_nan () && c.longitude.is_nan ()))
            longitude = c.longitude;
        location_source = location.source;
        location_name = location.name;
    }

    /* Work out what the screen should show now and head there. */
    public void evaluate (bool instant = false) {
        if (shutting_down)
            return;
        schedule.tz = clock.tz;
        update_location ();
        int64 now = clock.now ();
        expire_overrides (now);

        Transition prev, next;
        bool has_prev, has_next, night;
        schedule.find (now, out prev, out has_prev, out next, out has_next, out night);
        double scheduled = schedule.temperature_at (now, day_temperature, night_temperature, out night);

        bool activated = temporarily_activated (now);
        bool deactivated = temporarily_deactivated (now);
        running = (enabled || activated) && !inhibited;

        if (activated)
            daylight = false;
        else if (deactivated || !enabled)
            daylight = true;
        else
            daylight = !night;

        bool follows_schedule = running && !activated && !deactivated && mode != "always";
        previous_transition_start = follows_schedule && has_prev ? prev.start : 0;
        previous_transition_duration = follows_schedule && has_prev ? (uint) prev.duration : 0;
        next_transition_start = follows_schedule && has_next ? next.start : 0;
        next_transition_duration = follows_schedule && has_next ? (uint) next.duration : 0;

        double sr, ss;
        schedule.sun_hours (now, out sr, out ss);
        sunrise = schedule.uses_sun ? sr : -1;
        sunset = schedule.uses_sun ? ss : -1;

        double target;
        if (previewing)
            target = preview_temperature;
        else if (!running)
            target = ColorRamp.NEUTRAL_TEMPERATURE;
        else if (activated)
            target = night_temperature;
        else if (deactivated)
            target = day_temperature;
        else if (mode == "always")
            target = night_temperature;
        else
            target = scheduled;

        go_to (target, instant);
        schedule_tick ();
    }

    /* Wake up when the wanted temperature next changes. */
    private void schedule_tick () {
        if (tick_id != 0)
            Source.remove (tick_id);
        tick_id = 0;
        if (anim_id != 0 || shutting_down)
            return;   // re-armed when the animation ends

        int64 now = clock.now ();
        int64 wait = IDLE_TICK_MS;
        bool in_transition = previous_transition_start > 0 &&
                             now < (int64) previous_transition_start + previous_transition_duration;
        if (in_transition && !previewing)
            wait = TRANSITION_TICK_MS;
        else if (next_transition_start > 0)
            wait = int64.min (wait, ((int64) next_transition_start - now) * 1000);
        foreach (var until in new uint64[] { activated_until, deactivated_until }) {
            if (until > 0)
                wait = int64.min (wait, ((int64) until - OVERRIDE_SLACK - now) * 1000);
        }
        // Also covers clock changes we fail to notice: never sleep past a minute.
        tick_id = Timeout.add ((uint) wait.clamp (50, IDLE_TICK_MS), () => {
            tick_id = 0;
            evaluate ();
            return Source.REMOVE;
        });
    }

    /* ---- inhibit ---- */

    private void update_inhibited () {
        string[] reasons = {};
        foreach (var inh in inhibitor_table.get_values ())
            reasons += inh.reason;
        inhibitors = reasons;
        bool now_inhibited = inhibitor_table.size () > 0;
        if (now_inhibited != inhibited) {
            inhibited = now_inhibited;
            message (inhibited ? "Night Light inhibited" : "Night Light no longer inhibited");
            evaluate ();
        }
    }

    /* `owner` is a D-Bus unique name to watch, or null for internal use. */
    public uint inhibit (string reason, string? owner, DBusConnection? bus) {
        var inh = new Inhibitor ();
        inh.cookie = next_cookie++;
        inh.owner = owner ?? "";
        inh.reason = reason;
        if (owner != null && bus != null) {
            inh.watch_id = Bus.watch_name_on_connection (bus, owner, BusNameWatcherFlags.NONE, null,
                                                         (conn, name) => release_owner (name));
        }
        inhibitor_table[inh.cookie] = inh;
        update_inhibited ();
        return inh.cookie;
    }

    public bool uninhibit (uint cookie, string? owner) {
        var inh = inhibitor_table[cookie];
        if (inh == null || (owner != null && inh.owner != owner))
            return false;
        if (inh.watch_id != 0)
            Bus.unwatch_name (inh.watch_id);
        inhibitor_table.remove (cookie);
        update_inhibited ();
        return true;
    }

    /* Drop everything a client held when it leaves the bus. */
    private void release_owner (string owner) {
        foreach (var inh in inhibitor_table.get_values ()) {
            if (inh.owner == owner) {
                debug ("%s left the bus; releasing its inhibitor", owner);
                uninhibit (inh.cookie, null);
            }
        }
    }

    /* KWin's global shortcut action: suspend or resume Night Light. */
    public void toggle () {
        if (toggle_cookie != 0) {
            uninhibit (toggle_cookie, null);
            toggle_cookie = 0;
        } else {
            toggle_cookie = inhibit ("Toggled off", null, null);
        }
    }

    /* ---- preview ---- */

    public void preview (uint temperature) {
        preview_temperature = ColorRamp.clamp_temperature (temperature);
        previewing = true;
        if (preview_timeout_id != 0)
            Source.remove (preview_timeout_id);
        preview_timeout_id = Timeout.add_seconds (PREVIEW_TIMEOUT_S, () => {
            preview_timeout_id = 0;
            stop_preview ();
            return Source.REMOVE;
        });
        evaluate ();
    }

    public void stop_preview () {
        if (!previewing)
            return;
        if (preview_timeout_id != 0)
            Source.remove (preview_timeout_id);
        preview_timeout_id = 0;
        previewing = false;
        evaluate ();
    }

    /* ---- overrides ---- */

    private void set_override (uint64 act_until, bool act_manual, uint64 deact_until, bool deact_manual) {
        activated_until = act_until;
        activated_manual = act_manual;
        deactivated_until = deact_until;
        deactivated_manual = deact_manual;
        save_state ();
        evaluate ();
    }

    /* Night temperature until `until` (Unix time); 0 means until the next
     * morning. */
    public void activate_until (uint64 until) {
        if (until == 0)
            until = schedule.next_morning_end (clock.now ());
        set_override (until, false, 0, false);
    }

    public void activate_manual (bool on) {
        set_override (0, on, 0, false);
    }

    /* Day temperature until `until`; 0 means "until tomorrow", i.e. until
     * the next night is over, like GNOME's. */
    public void deactivate_until (uint64 until) {
        if (until == 0)
            until = schedule.next_morning_end (clock.now ());
        set_override (0, false, until, false);
    }

    public void deactivate_manual (bool off) {
        set_override (0, false, 0, off);
    }

    public void clear_override () {
        set_override (0, false, 0, false);
    }

    public void reapply () {
        if (backend != null)
            backend.force_reapply ();
        evaluate (true);
    }

    /* ---- shutdown ---- */

    /* Fade back to neutral and give the outputs back. */
    public async void shutdown () {
        shutting_down = true;
        if (preview_timeout_id != 0)
            Source.remove (preview_timeout_id);
        preview_timeout_id = 0;
        if (tick_id != 0)
            Source.remove (tick_id);
        tick_id = 0;
        if (backend != null && smooth && !ColorRamp.is_neutral (shown)) {
            wanted = ColorRamp.NEUTRAL_TEMPERATURE;
            stop_animation ();
            animate (SHUTDOWN_FADE_US);
            while (anim_id != 0) {
                Timeout.add (FRAME_MS, shutdown.callback);
                yield;
            }
        }
        stop_animation ();
        if (tick_id != 0)
            Source.remove (tick_id);
        tick_id = 0;
        if (backend != null)
            backend.release ();
    }
}

}
