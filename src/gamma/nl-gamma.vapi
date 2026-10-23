/* Bindings for nl-gamma.h. */

[CCode (cheader_filename = "nl-gamma.h")]
namespace Nl {
    [CCode (cname = "NlGammaError", cprefix = "NL_GAMMA_ERROR_")]
    public errordomain GammaError {
        NO_DISPLAY,
        UNSUPPORTED,
        NOT_BUILT;
        public static GLib.Quark quark ();
    }

    [CCode (cname = "NlGammaNotify", has_target = true)]
    public delegate void GammaNotify ();

    [Compact]
    [CCode (cname = "NlGamma", cprefix = "nl_gamma_", free_function = "nl_gamma_free")]
    public class Gamma {
        [CCode (cname = "nl_gamma_x11_new")]
        public static Gamma? x11_new (string? display_name) throws GammaError;
        [CCode (cname = "nl_gamma_wayland_new")]
        public static Gamma? wayland_new (string? display_name) throws GammaError;

        public unowned string get_name ();
        public int get_fd ();
        public bool dispatch ();
        /* The callback must outlive the Gamma; there is no destroy notify. */
        public void set_notify (GammaNotify? func);
        public void set_preserve_calibration (bool preserve);
        public bool apply (double r, double g, double b);
        public bool verify ();
        public void force_reapply ();
        public void release ();
        public uint get_n_outputs ();
        public uint get_n_busy ();
    }
}
