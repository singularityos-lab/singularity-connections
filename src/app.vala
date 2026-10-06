using Gtk;

namespace Singularity.Apps.Connections {

    public class ConnectionsApp : Singularity.Application {
        public Store store;
        private Singularity.DockMenu dock_menu;
        private bool new_pending;

        public ConnectionsApp () {
            Object (application_id: "dev.sinty.connections", flags: ApplicationFlags.HANDLES_OPEN);
            add_main_option ("new-connection", 0, OptionFlags.NONE, OptionArg.NONE, _("Add a connection"), null);
        }

        protected override int handle_local_options (VariantDict options) {
            if (!options.contains ("new-connection")) return -1;
            try {
                register (null);
            } catch (Error e) {
                warning ("connections: %s", e.message);
                return 1;
            }
            if (get_is_remote ()) {
                activate_action ("new-connection", null);
                return 0;
            }
            new_pending = true;
            return -1;
        }

        protected override void startup () {
            base.startup ();
            if (store == null) store = new Store ();
            dock_menu = new Singularity.DockMenu ("dev.sinty.connections");
            dock_menu.activated.connect ((id) => connect_saved (id));
            store.changed.connect (publish_recent);
            publish_recent ();
            var provider = new CssProvider ();
            provider.load_from_string (CSS);
            StyleContext.add_provider_for_display (Gdk.Display.get_default (), provider, STYLE_PROVIDER_PRIORITY_USER + 1);
            var menu = new GLib.Menu ();
            var file = new GLib.Menu ();
            var f1 = new GLib.Menu ();
            f1.append (_("New Connection…"), "win.new");
            f1.append (_("Open Connection File…"), "win.open");
            file.append_section (null, f1);
            var f2 = new GLib.Menu ();
            f2.append (_("Close Window"), "win.close");
            f2.append (_("Quit"), "app.quit");
            file.append_section (null, f2);
            menu.append_submenu (_("File"), file);
            var edit = new GLib.Menu ();
            var e1 = new GLib.Menu ();
            e1.append (_("Find"), "win.find");
            edit.append_section (null, e1);
            var e2 = new GLib.Menu ();
            e2.append (_("Settings"), "app.settings");
            edit.append_section (null, e2);
            menu.append_submenu (_("Edit"), edit);
            var view = new GLib.Menu ();
            view.append (_("Fit to Window"), "win.fit");
            view.append (_("Fullscreen"), "win.fullscreen");
            menu.append_submenu (_("View"), view);
            var connection = new GLib.Menu ();
            var c1 = new GLib.Menu ();
            c1.append (_("Send Ctrl+Alt+Del"), "win.send-ctrl-alt-del");
            c1.append (_("Send Ctrl+Alt+Backspace"), "win.send-ctrl-alt-backspace");
            connection.append_section (null, c1);
            var c2 = new GLib.Menu ();
            c2.append (_("View Only"), "win.view-only");
            c2.append (_("Take a Screenshot"), "win.screenshot");
            connection.append_section (null, c2);
            var c3 = new GLib.Menu ();
            c3.append (_("Disconnect"), "win.disconnect");
            connection.append_section (null, c3);
            menu.append_submenu (_("Connection"), connection);
            set_menubar (menu);
            var quit = new SimpleAction ("quit", null);
            quit.activate.connect (() => {
                foreach (var w in get_windows ()) w.close ();
            });
            add_action (quit);
            var settings_action = new SimpleAction ("settings", null);
            settings_action.activate.connect (() => {
                try {
                    Singularity.Shell.ShellService shell = Bus.get_proxy_sync (BusType.SESSION, "dev.sinty.desktop", "/dev/sinty/Shell");
                    shell.open_app_settings ("dev.sinty.connections");
                } catch (Error e) {
                    warning ("Failed to open settings: %s", e.message);
                }
            });
            add_action (settings_action);
            var new_connection = new SimpleAction ("new-connection", null);
            new_connection.activate.connect (() => {
                var w = window ();
                w.present ();
                w.edit_connection (null);
            });
            add_action (new_connection);
            set_accels_for_action ("app.settings", { "<Control>comma" });
            set_accels_for_action ("win.close", { "<Control>w" });
            set_accels_for_action ("app.quit", { "<Control>q" });
            set_accels_for_action ("win.new", { "<Control>n" });
            set_accels_for_action ("win.open", { "<Control>o" });
            set_accels_for_action ("win.find", { "<Control>f" });
            set_accels_for_action ("win.fullscreen", { "F11" });
        }

        private ConnectionsWindow window () {
            var w = get_active_window () as ConnectionsWindow;
            if (w == null) w = new ConnectionsWindow (this, store);
            return w;
        }

        public override void activate () {
            var w = window ();
            w.present ();
            if (new_pending) {
                new_pending = false;
                w.edit_connection (null);
            }
        }

        public void connect_saved (string id) {
            var c = store.find (id);
            if (c == null) return;
            var w = window ();
            w.present ();
            w.connect_to (c);
        }

        private void publish_recent () {
            dock_menu.clear ();
            int added = 0;
            foreach (var c in store.sorted ()) {
                if (c.last_used <= 0 || added >= 5) break;
                string label = c.name != "" && c.name != c.address ()
                    ? _("%s, %s (%s)").printf (c.name, c.address (), c.protocol.up ())
                    : "%s (%s)".printf (c.address (), c.protocol.up ());
                dock_menu.add_item (c.id, label, "network-server-symbolic");
                added++;
            }
            if (added > 0) dock_menu.publish ();
            else dock_menu.unpublish ();
        }

        public override void open (File[] files, string hint) {
            var w = window ();
            w.present ();
            if (files.length > 0) w.open_target (files[0]);
        }

        private const string CSS = """
.conn-card {
    padding: 8px;
    border-radius: 18px;
    background: transparent;
}

.conn-card:hover .conn-thumb {
    box-shadow: 0 0 0 3px alpha(@accent_bg_color, 0.55), 0 6px 18px alpha(black, 0.18);
}

.conn-thumb {
    border-radius: 14px;
    background-color: #1c1f26;
    box-shadow: 0 4px 14px alpha(black, 0.16);
    transition: box-shadow 150ms ease;
}

.conn-badge {
    font-size: 11px;
    font-weight: 800;
    letter-spacing: 1px;
    padding: 2px 8px;
    border-radius: 99px;
    color: white;
    background-color: alpha(black, 0.55);
}

.conn-name {
    font-weight: 700;
}

.conn-stage {
    background-color: #0e1014;
}

.conn-status {
    padding: 28px 36px;
    border-radius: 24px;
    background-color: @window_bg_color;
    color: @window_fg_color;
    box-shadow: 0 10px 40px alpha(black, 0.35);
}

.conn-fingerprint {
    padding: 10px 14px;
    border-radius: 12px;
    background-color: alpha(@window_fg_color, 0.06);
    font-size: 12px;
}

.conn-toast {
    padding: 8px 16px;
    border-radius: 18px;
    background-color: alpha(black, 0.7);
    color: white;
}

.remote-display:focus-visible {
    outline: none;
}

""";
    }

    public static int main (string[] args) {
        Intl.setlocale (LocaleCategory.ALL, "");
        string locale_dir = "/usr/share/locale";
        try {
            string exe = FileUtils.read_link ("/proc/self/exe");
            locale_dir = Path.build_filename (Path.get_dirname (Path.get_dirname (exe)), "share", "locale");
        } catch (Error e) {
        }
        Intl.bindtextdomain ("singularity-connections", locale_dir);
        Intl.bind_textdomain_codeset ("singularity-connections", "UTF-8");
        Intl.textdomain ("singularity-connections");
        var app = new ConnectionsApp ();
        new ConnectionsSearch (app).export (app);
        return app.run (args);
    }
}
