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

/* Picks the gamma backend for this session and hooks it into the main loop. */

namespace Rojo {

public class GammaBackend : Object {
    public signal void outputs_changed ();
    public signal void lost ();

    public string name { get; private set; }
    public uint n_outputs { get { return impl.get_n_outputs (); } }
    public uint n_busy { get { return impl.get_n_busy (); } }

    private Nl.Gamma impl;
    private uint watch_id = 0;
    private bool tinted = false;

    private GammaBackend (owned Nl.Gamma impl) {
        this.impl = (owned) impl;
        name = this.impl.get_name ();
        this.impl.set_notify (on_notify);
        var channel = new IOChannel.unix_new (this.impl.get_fd ());
        watch_id = channel.add_watch (IOCondition.IN | IOCondition.HUP | IOCondition.ERR, (ch, cond) => {
            if ((cond & (IOCondition.HUP | IOCondition.ERR)) != 0 || !this.impl.dispatch ()) {
                watch_id = 0;
                warning ("Lost the connection to the display server");
                lost ();
                return Source.REMOVE;
            }
            return Source.CONTINUE;
        });
    }

    ~GammaBackend () {
        if (watch_id != 0)
            Source.remove (watch_id);
    }

    private void on_notify () {
        outputs_changed ();
    }

    /* `force`: "x11" or "wayland" to skip detection. On a Wayland session
     * the X11 backend would only reach Xwayland, whose ramps do nothing, so
     * it isn't tried there. */
    public static GammaBackend? create (string? force, out string error) {
        error = "";
        var wayland = Environment.get_variable ("WAYLAND_DISPLAY");
        var session = Environment.get_variable ("XDG_SESSION_TYPE");
        bool on_wayland = force == "wayland" ||
                          (force == null && (wayland != null || session == "wayland"));
        try {
            // Not a ?: expression; older valac copies owned compact objects there.
            Nl.Gamma? impl;
            if (on_wayland)
                impl = Nl.Gamma.wayland_new (null);
            else
                impl = Nl.Gamma.x11_new (null);
            return new GammaBackend ((owned) impl);
        } catch (Nl.GammaError e) {
            error = e.message;
            return null;
        }
    }

    public void set_preserve_calibration (bool preserve) {
        impl.set_preserve_calibration (preserve);
        if (tinted)
            impl.force_reapply ();
    }

    /* Show `temperature`; at neutral this lets go of the outputs. */
    public void show (double temperature) {
        if (ColorRamp.is_neutral (temperature)) {
            release ();
            return;
        }
        double r, g, b;
        ColorRamp.factors (temperature, out r, out g, out b);
        impl.apply (r, g, b);
        tinted = true;
    }

    /* Put our ramps back if someone else changed them. */
    public bool verify () {
        return !tinted || impl.verify ();
    }

    public void force_reapply () {
        if (tinted)
            impl.force_reapply ();
    }

    public void release () {
        if (!tinted)
            return;
        impl.release ();
        tinted = false;
    }
}

}
