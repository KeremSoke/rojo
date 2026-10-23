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

/* org.mate.rojo.NightLight on the session bus; see data/org.mate.rojo.NightLight.xml.
 *
 * Settings (enabled, temperatures, schedule, location) live in GSettings
 * (org.mate.rojo.nightlight) and are changed there. This interface is for
 * state and for things that aren't settings: overrides, inhibition and
 * preview. Every property emits PropertiesChanged.
 */

namespace Rojo {

[DBus (name = "org.mate.rojo.NightLight")]
public class Service : Object {
    public const string BUS_NAME = "org.mate.rojo";
    public const string OBJECT_PATH = "/org/mate/rojo";

    public bool available { get { return manager.available; } }
    public string backend { owned get { return manager.backend_name; } }
    public string backend_status { owned get { return manager.backend_status; } }
    public bool enabled { get { return manager.enabled; } }
    public string mode { owned get { return manager.mode; } }
    public bool running { get { return manager.running; } }
    public bool daylight { get { return manager.daylight; } }
    public bool inhibited { get { return manager.inhibited; } }
    public string[] inhibitors { owned get { return manager.inhibitors; } }
    public bool previewing { get { return manager.previewing; } }
    public uint current_temperature { get { return manager.current_temperature; } }
    public uint target_temperature { get { return manager.target_temperature; } }
    public double latitude { get { return manager.latitude.is_nan () ? 91.0 : manager.latitude; } }
    public double longitude { get { return manager.longitude.is_nan () ? 181.0 : manager.longitude; } }
    public string location_source { owned get { return manager.location_source; } }
    public string location_name { owned get { return manager.location_name; } }
    public double sunrise { get { return manager.sunrise; } }
    public double sunset { get { return manager.sunset; } }
    public uint64 previous_transition_date_time { get { return manager.previous_transition_start; } }
    public uint previous_transition_duration { get { return manager.previous_transition_duration; } }
    public uint64 scheduled_transition_date_time { get { return manager.next_transition_start; } }
    public uint scheduled_transition_duration { get { return manager.next_transition_duration; } }
    public uint64 activated_until { get { return manager.activated_until; } }
    public bool activated_manual { get { return manager.activated_manual; } }
    public uint64 deactivated_until { get { return manager.deactivated_until; } }
    public bool deactivated_manual { get { return manager.deactivated_manual; } }

    /* PropertiesChanged is sent at most this often; fades change the
     * temperature every frame, and clients don't need every one. */
    private const uint EMIT_INTERVAL_MS = 50;

    private Manager manager;
    private DBusConnection bus;
    private HashTable<string, Variant> pending = new HashTable<string, Variant> (str_hash, str_equal);
    private uint emit_id = 0;

    [DBus (visible = false)]
    public Service (Manager manager, DBusConnection bus) {
        this.manager = manager;
        this.bus = bus;
        // Vala doesn't send PropertiesChanged for computed properties, so
        // forward the manager's notifications ourselves. Latitude and
        // longitude use an out-of-range value for "unknown", as GNOME does,
        // since D-Bus clients handle NaN poorly.
        manager.notify.connect ((pspec) => {
            var name = pspec.name;
            switch (name) {
            case "backend-name": name = "backend"; break;
            case "previous-transition-start": name = "previous-transition-date-time"; break;
            case "next-transition-start": name = "scheduled-transition-date-time"; break;
            case "next-transition-duration": name = "scheduled-transition-duration"; break;
            }
            var own = get_class ().find_property (name);
            if (own == null)
                return;
            var value = to_variant (own);
            if (value == null)
                return;
            pending[dbus_name (name)] = value;
            if (emit_id == 0)
                emit_id = Timeout.add (EMIT_INTERVAL_MS, emit_changes);
        });
    }

    /* "current-temperature" → "CurrentTemperature" */
    private static string dbus_name (string name) {
        var sb = new StringBuilder ();
        foreach (var part in name.split ("-"))
            sb.append (part.substring (0, 1).up () + part.substring (1));
        return sb.str;
    }

    private Variant? to_variant (ParamSpec pspec) {
        var v = Value (pspec.value_type);
        get_property (pspec.name, ref v);
        var t = pspec.value_type;
        if (t == typeof (bool))
            return new Variant.boolean (v.get_boolean ());
        if (t == typeof (uint))
            return new Variant.uint32 (v.get_uint ());
        if (t == typeof (uint64))
            return new Variant.uint64 (v.get_uint64 ());
        if (t == typeof (double))
            return new Variant.double (v.get_double ());
        if (t == typeof (string))
            return new Variant.string (v.get_string () ?? "");
        if (t == typeof (string[]))
            return new Variant.strv ((string[]) v.get_boxed ());
        return null;
    }

    private bool emit_changes () {
        emit_id = 0;
        var changed = new VariantBuilder (new VariantType ("a{sv}"));
        pending.foreach ((name, value) => changed.add ("{sv}", name, value));
        pending.remove_all ();
        try {
            bus.emit_signal (null, OBJECT_PATH, "org.freedesktop.DBus.Properties", "PropertiesChanged",
                             new Variant ("(sa{sv}as)", "org.mate.rojo.NightLight", changed, null));
        } catch (Error e) {
            warning ("Cannot send PropertiesChanged: %s", e.message);
        }
        return Source.REMOVE;
    }

    /* Keep the screen at neutral until Uninhibit(). Released automatically
     * when the caller leaves the bus. */
    public uint inhibit (string reason, BusName sender) throws Error {
        return manager.inhibit (reason, sender, bus);
    }

    public void uninhibit (uint cookie, BusName sender) throws Error {
        if (!manager.uninhibit (cookie, sender))
            throw new DBusError.INVALID_ARGS ("No inhibitor %u held by %s", cookie, sender);
    }

    /* Suspend or resume Night Light, for a keyboard shortcut or a panel. */
    public void toggle () throws Error {
        manager.toggle ();
    }

    /* Show `temperature` for 15 seconds, or until StopPreview(). */
    public void preview (uint temperature) throws Error {
        manager.preview (temperature);
    }

    public void stop_preview () throws Error {
        manager.stop_preview ();
    }

    /* Unix time; 0 means until the next morning. */
    public void activate_until (uint64 until) throws Error {
        manager.activate_until (until);
    }

    public void activate_manual (bool on) throws Error {
        manager.activate_manual (on);
    }

    /* Unix time; 0 means until tomorrow (the end of the next night). */
    public void deactivate_until (uint64 until) throws Error {
        manager.deactivate_until (until);
    }

    public void deactivate_manual (bool off) throws Error {
        manager.deactivate_manual (off);
    }

    public void clear_override () throws Error {
        manager.clear_override ();
    }

    /* Send the ramps again (e.g. after something outside our view reset them). */
    public void reapply () throws Error {
        manager.reapply ();
    }
}

}
