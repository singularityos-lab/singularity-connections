using Singularity.Remote;

namespace Singularity.Apps.Connections {

    public class RdpSession : RemoteSession {
        private RdpBridge.Client? client;
        private Framebuffer fb = new Framebuffer ();
        private uint buttons_down;
        private bool closing;
        private bool reported;
        private int initial_width;
        private int initial_height;

        public RdpSession (string host, int port, int width, int height) {
            Object (host: host, port: port);
            initial_width = width;
            initial_height = height;
        }

        public override void start () {
            if (password == "") {
                credentials_needed (true, null);
                return;
            }
            launch ();
        }

        private void launch () {
            client = RdpBridge.Client.create (host, port, username, password, domain, trusted_fingerprint,
                initial_width, initial_height, on_ready, on_frame, on_closed, this);
            if (client != null) client.set_clipboard_callback (on_clipboard);
            if (client == null || !client.start ()) {
                client = null;
                report (new SessionError.FAILED (_("The remote desktop connection could not be started.")));
            }
        }

        public override void provide_credentials (string username, string password, string domain) {
            this.username = username;
            this.password = password;
            this.domain = domain;
            if (!closing && client == null) launch ();
        }

        public override void stop () {
            if (closing) return;
            closing = true;
            active = false;
            if (client != null) client.stop ();
            else report (null);
        }

        private void report (Error? error) {
            if (reported) return;
            reported = true;
            active = false;
            closed (error);
        }

        private static void on_ready (void* data) {
            var self = (RdpSession) data;
            self.active = true;
            self.sync_size ();
            self.ready ();
        }

        private static void on_frame (void* data) {
            var self = (RdpSession) data;
            self.pull ();
        }

        private static void on_clipboard (string text, void* data) {
            var self = (RdpSession) data;
            self.remote_clipboard (text.replace ("\r\n", "\n"));
        }

        private static void on_closed (int kind, string? message, void* data) {
            var self = (RdpSession) data;
            self.handle_closed (kind, message);
        }

        private void handle_closed (int kind, string? message) {
            string fp = client != null ? client.get_pending_fingerprint () : "";
            client = null;
            if (closing || kind == RdpBridge.CLOSED_OK) {
                report (null);
                return;
            }
            if (kind == RdpBridge.CLOSED_UNTRUSTED) {
                pending_fingerprint = fp;
                report (new SessionError.UNTRUSTED (_("The identity of the remote computer could not be verified.")));
            } else if (kind == RdpBridge.CLOSED_AUTH) {
                password = "";
                if (!active) {
                    credentials_needed (true, _("The user name or password was not accepted."));
                    return;
                }
                report (new SessionError.AUTH_FAILED (_("The user name or password was not accepted.")));
            } else {
                report (new SessionError.FAILED (message ?? _("The connection to the remote computer was lost.")));
            }
        }

        private bool sync_size () {
            int w = client.get_width ();
            int h = client.get_height ();
            if (w <= 0 || h <= 0) return false;
            if (w != fb.width || h != fb.height) {
                fb.resize (w, h);
                width = w;
                height = h;
            }
            return true;
        }

        private void pull () {
            if (client == null || !sync_size ()) return;
            int x, y, w, h;
            if (client.blit (fb.data, fb.width, fb.height, out x, out y, out w, out h)) fb.add_damage (x, y, w, h);
            var t = fb.commit ();
            if (t == null) return;
            texture = t;
            frame ();
        }

        public override void send_pointer (int x, int y, uint buttons) {
            if (client == null || !active || view_only) return;
            x = x.clamp (0, int.max (fb.width - 1, 0));
            y = y.clamp (0, int.max (fb.height - 1, 0));
            uint changed = buttons ^ buttons_down;
            buttons_down = buttons;
            if (changed == 0) {
                client.send_mouse (0x0800, x, y);
                return;
            }
            uint16[] flags = { 0x1000, 0x4000, 0x2000 };
            for (int i = 0; i < 3; i++) {
                uint bit = 1 << i;
                if ((changed & bit) == 0) continue;
                uint16 f = flags[i];
                if ((buttons & bit) != 0) f |= 0x8000;
                client.send_mouse (f, x, y);
            }
        }

        public override void send_scroll (int x, int y, double dx, double dy) {
            if (client == null || !active || view_only) return;
            if (dy != 0) client.send_mouse (dy < 0 ? (uint16) (0x0200 | 0x78) : (uint16) (0x0200 | 0x0100 | 0x88), x, y);
            if (dx != 0) client.send_mouse (dx > 0 ? (uint16) (0x0400 | 0x78) : (uint16) (0x0400 | 0x0100 | 0x88), x, y);
        }

        public override void send_key (uint keyval, uint keycode, bool pressed) {
            if (client == null || !active || view_only) return;
            uint32 sc = keycode > 8 ? Keymap.scancode_from_evdev (keycode - 8) : 0;
            if (sc == 0) sc = Keymap.scancode_from_keyval (keyval);
            if (sc != 0) {
                client.send_key (pressed, sc);
                return;
            }
            unichar u = Gdk.keyval_to_unicode (keyval);
            if (u != 0 && u < 0x10000) client.send_unicode (pressed, (uint16) u);
        }

        public override void send_clipboard (string text) {
            if (client == null || !active || view_only) return;
            client.set_clipboard (text);
        }
    }

    namespace Keymap {
        public uint32 scancode_from_evdev (uint code) {
            if (code >= 1 && code <= 83) return code;
            switch (code) {
                case 86: return 0x56;
                case 87: return 0x57;
                case 88: return 0x58;
                case 96: return 0x11C;
                case 97: return 0x11D;
                case 98: return 0x135;
                case 99: return 0x137;
                case 100: return 0x138;
                case 102: return 0x147;
                case 103: return 0x148;
                case 104: return 0x149;
                case 105: return 0x14B;
                case 106: return 0x14D;
                case 107: return 0x14F;
                case 108: return 0x150;
                case 109: return 0x151;
                case 110: return 0x152;
                case 111: return 0x153;
                case 119: return 0x45;
                case 125: return 0x15B;
                case 126: return 0x15C;
                case 127: return 0x15D;
                default: return 0;
            }
        }

        public uint32 scancode_from_keyval (uint keyval) {
            switch (keyval) {
                case Gdk.Key.Control_L: return 0x1D;
                case Gdk.Key.Control_R: return 0x11D;
                case Gdk.Key.Alt_L: return 0x38;
                case Gdk.Key.Alt_R: return 0x138;
                case Gdk.Key.Shift_L: return 0x2A;
                case Gdk.Key.Shift_R: return 0x36;
                case Gdk.Key.Super_L: return 0x15B;
                case Gdk.Key.Delete: return 0x153;
                case Gdk.Key.BackSpace: return 0x0E;
                case Gdk.Key.Tab: return 0x0F;
                case Gdk.Key.Escape: return 0x01;
                case Gdk.Key.Return: return 0x1C;
                case Gdk.Key.Print: return 0x137;
                case Gdk.Key.F1: return 0x3B;
                case Gdk.Key.F2: return 0x3C;
                case Gdk.Key.F3: return 0x3D;
                case Gdk.Key.F4: return 0x3E;
                case Gdk.Key.F5: return 0x3F;
                case Gdk.Key.F6: return 0x40;
                case Gdk.Key.F7: return 0x41;
                case Gdk.Key.F8: return 0x42;
                case Gdk.Key.F9: return 0x43;
                case Gdk.Key.F10: return 0x44;
                case Gdk.Key.F11: return 0x57;
                case Gdk.Key.F12: return 0x58;
                default: return 0;
            }
        }
    }
}
