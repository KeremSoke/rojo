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

[CCode (cname = "PACKAGE_VERSION")]
extern const string PACKAGE_VERSION;

namespace Rojo {

private bool opt_replace = false;
private bool opt_verbose = false;
private bool opt_version = false;
private string? opt_backend = null;

private const OptionEntry[] OPTIONS = {
    { "replace", 'r', 0, OptionArg.NONE, ref opt_replace, "Replace a running instance", null },
    { "verbose", 'v', 0, OptionArg.NONE, ref opt_verbose, "Print debugging messages", null },
    { "backend", 'b', 0, OptionArg.STRING, ref opt_backend, "Use this backend instead of detecting one", "x11|wayland" },
    { "version", 0, 0, OptionArg.NONE, ref opt_version, "Print the version and exit", null },
    { null }
};

public class Daemon : Object {
    private MainLoop loop = new MainLoop ();
    private Manager? manager;
    private Service? service;
    private uint owner_id = 0;
    private uint object_id = 0;
    private DBusConnection? bus;
    private bool quitting = false;
    private int status = 0;

    public int run () {
        foreach (var sig in new int[] { Posix.Signal.TERM, Posix.Signal.INT, Posix.Signal.HUP }) {
            Unix.signal_add (sig, () => {
                quit ();
                return Source.REMOVE;
            });
        }

        var flags = BusNameOwnerFlags.ALLOW_REPLACEMENT;
        if (opt_replace)
            flags |= BusNameOwnerFlags.REPLACE;
        owner_id = Bus.own_name (BusType.SESSION, Service.BUS_NAME, flags,
                                 on_bus_acquired, null, on_name_lost);
        loop.run ();
        return status;
    }

    private void on_bus_acquired (DBusConnection conn, string name) {
        bus = conn;
        manager = new Manager (new Settings ("org.mate.rojo.nightlight"), opt_backend);
        manager.lost.connect (() => quit (1));
        service = new Service (manager, conn);
        try {
            object_id = conn.register_object (Service.OBJECT_PATH, service);
        } catch (IOError e) {
            critical ("Cannot export %s: %s", Service.OBJECT_PATH, e.message);
            quit (1);
        }
    }

    private void on_name_lost (DBusConnection? conn, string name) {
        if (conn == null)
            critical ("Cannot connect to the session bus");
        else if (manager == null)
            message ("Another Night Light daemon is running; use --replace to replace it");
        else
            message ("Replaced by another instance");
        quit (manager == null ? 1 : 0);
    }

    private void quit (int code = 0) {
        if (quitting)
            return;
        quitting = true;
        status = code;
        if (object_id != 0 && bus != null)
            bus.unregister_object (object_id);
        object_id = 0;
        if (manager == null) {
            loop.quit ();
            return;
        }
        manager.shutdown.begin ((obj, res) => {
            manager.shutdown.end (res);
            if (owner_id != 0)
                Bus.unown_name (owner_id);
            loop.quit ();
        });
    }
}

}

int main (string[] args) {
    try {
        var ctx = new OptionContext ("— MATE Night Light daemon");
        ctx.add_main_entries (Rojo.OPTIONS, null);
        ctx.parse (ref args);
    } catch (OptionError e) {
        printerr ("%s\n", e.message);
        return 2;
    }
    if (Rojo.opt_version) {
        print ("rojo %s\n", PACKAGE_VERSION);
        return 0;
    }
    if (Rojo.opt_backend != null &&
        Rojo.opt_backend != "x11" && Rojo.opt_backend != "wayland") {
        printerr ("Unknown backend %s\n", Rojo.opt_backend);
        return 2;
    }
    if (Rojo.opt_verbose)
        Environment.set_variable ("G_MESSAGES_DEBUG", "rojo", true);
    Environment.set_prgname ("rojo");
    return new Rojo.Daemon ().run ();
}
