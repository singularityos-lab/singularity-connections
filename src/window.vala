using Gtk;
using Singularity.Widgets;
using Singularity.Remote;

namespace Singularity.Apps.Connections {

    public delegate void Validator ();

    public class Thumbnail : Widget {
        private Gdk.Texture? texture;
        public int thumb_width { get; construct; }
        public int thumb_height { get; construct; }

        public Thumbnail (string path, int w, int h) {
            Object (thumb_width: w, thumb_height: h);
            try {
                texture = Gdk.Texture.from_filename (path);
            } catch (Error e) {
                texture = null;
            }
        }

        protected override void measure (Orientation orientation, int for_size, out int minimum, out int natural, out int minimum_baseline, out int natural_baseline) {
            minimum = natural = orientation == Orientation.HORIZONTAL ? thumb_width : thumb_height;
            minimum_baseline = natural_baseline = -1;
        }

        protected override void snapshot (Gtk.Snapshot snapshot) {
            if (texture == null) return;
            double w = get_width (), h = get_height ();
            double scale = double.max (w / texture.width, h / texture.height);
            double dw = texture.width * scale, dh = texture.height * scale;
            var rect = Graphene.Rect ().init ((float) ((w - dw) / 2), (float) ((h - dh) / 2), (float) dw, (float) dh);
            snapshot.append_scaled_texture (texture, Gsk.ScalingFilter.TRILINEAR, rect);
        }
    }

    public class ConnectionCard : FlowBoxChild {
        public Connection connection;

        public ConnectionCard (Connection c) {
            connection = c;
            add_css_class ("conn-card");
            var box = new Box (Orientation.VERTICAL, 8);

            var thumb = new Overlay ();
            thumb.add_css_class ("conn-thumb");
            thumb.overflow = Overflow.HIDDEN;
            thumb.set_size_request (232, 145);
            string path = Store.thumbnail_path (c.id);
            if (FileUtils.test (path, FileTest.EXISTS)) {
                thumb.child = new Thumbnail (path, 232, 145);
            } else {
                var icon = new Image.from_icon_name ("computer");
                icon.pixel_size = 48;
                thumb.child = icon;
            }
            var badge = new Label (c.protocol.up ());
            badge.add_css_class ("conn-badge");
            badge.halign = Align.START;
            badge.valign = Align.START;
            badge.margin_start = 10;
            badge.margin_top = 10;
            thumb.add_overlay (badge);
            box.append (thumb);

            var name = new Label (c.title ());
            name.add_css_class ("conn-name");
            name.halign = Align.START;
            name.ellipsize = Pango.EllipsizeMode.END;
            name.max_width_chars = 24;
            box.append (name);
            if (c.name != "") {
                var addr = new Label (c.address ());
                addr.add_css_class ("dim-label");
                addr.add_css_class ("caption");
                addr.halign = Align.START;
                addr.ellipsize = Pango.EllipsizeMode.END;
                addr.max_width_chars = 28;
                box.append (addr);
            }
            child = box;
        }
    }

    public class ConnectionsWindow : Singularity.Widgets.Window {
        private Store store;
        private Stack stack;
        private FlowBox grid;
        private string filter = "";
        private RemoteDisplay display;
        private ScrolledWindow display_scroll;
        private Box status_box;
        private Spinner spinner;
        private Label status_title;
        private Label status_detail;
        private Button status_primary;
        private Button status_back;
        private RemoteSession? session;
        private Connection? current;
        private string? pending_password;
        private bool remember_pending;
        private Button add_bubble;
        private SearchBubble search_bubble;
        private SimpleAction find_action;
        private Gee.ArrayList<SimpleAction> session_actions = new Gee.ArrayList<SimpleAction> ();
        private SimpleAction disconnect_action;
        private SimpleAction fit_action;
        private SimpleAction view_only_action;
        private Gee.ArrayList<Widget> session_bubbles = new Gee.ArrayList<Widget> ();
        private Button fit_bubble;
        private Button full_bubble;
        private Label? toast;
        private uint toast_id;
        private string last_clipboard = "";
        private bool inhibiting;

        public ConnectionsWindow (Gtk.Application app, Store store) {
            Object (application: app);
            this.store = store;
            title = _("Connections");
            set_default_size (1100, 720);

            stack = new Stack ();
            stack.transition_type = StackTransitionType.CROSSFADE;
            stack.add_named (build_welcome (), "welcome");
            stack.add_named (build_list (), "list");
            stack.add_named (build_session (), "session");
            set_content (stack);

            add_bubble = add_bubble_icon ("list-add-symbolic", _("New Connection"), () => edit_connection (null));
            search_bubble = add_bubble_search (_("Search Connections"), (t) => {
                filter = t.strip ().down ();
                grid.invalidate_filter ();
            });
            find_action = new SimpleAction ("find", null);
            find_action.activate.connect (() => search_bubble.grab_focus_entry ());
            add_action (find_action);
            session_bubbles.add (add_bubble_icon ("go-previous-symbolic", _("Disconnect"), () => disconnect_session ()));
            fit_bubble = add_bubble_icon ("zoom-original-symbolic", _("Show at Original Size"), () => toggle_fit ());
            session_bubbles.add (fit_bubble);
            Button? keys_btn = null;
            keys_btn = add_bubble_icon ("input-keyboard-symbolic", _("Send Keys"), () => keys_menu (keys_btn));
            session_bubbles.add (keys_btn);
            session_bubbles.add (add_bubble_icon ("camera-photo-symbolic", _("Take a Screenshot"), () => screenshot ()));
            full_bubble = add_bubble_icon ("view-fullscreen-symbolic", _("Fullscreen"), () => {
                if (fullscreened) unfullscreen ();
                else fullscreen ();
            });
            session_bubbles.add (full_bubble);

            notify["fullscreened"].connect (() => {
                full_bubble.icon_name = fullscreened ? "view-restore-symbolic" : "view-fullscreen-symbolic";
                full_bubble.tooltip_text = fullscreened ? _("Leave Fullscreen") : _("Fullscreen");
            });
            notify["is-active"].connect (() => {
                if (is_active) push_clipboard ();
                else display.release_all ();
            });
            display.get_clipboard ().changed.connect (() => {
                if (!display.get_clipboard ().is_local ()) push_clipboard ();
            });
            var new_action = new SimpleAction ("new", null);
            new_action.activate.connect (() => edit_connection (null));
            add_action (new_action);
            var open_action = new SimpleAction ("open", null);
            open_action.activate.connect (() => open_file ());
            add_action (open_action);
            var full_action = new SimpleAction ("fullscreen", null);
            full_action.activate.connect (() => {
                if (fullscreened) unfullscreen ();
                else if (session != null) fullscreen ();
            });
            add_action (full_action);
            session_actions.add (full_action);
            disconnect_action = new SimpleAction ("disconnect", null);
            disconnect_action.activate.connect (() => disconnect_session ());
            add_action (disconnect_action);
            var close_action = new SimpleAction ("close", null);
            close_action.activate.connect (() => close ());
            add_action (close_action);
            fit_action = new SimpleAction.stateful ("fit", null, new Variant.boolean (true));
            fit_action.activate.connect (() => toggle_fit ());
            add_action (fit_action);
            session_actions.add (fit_action);
            view_only_action = new SimpleAction.stateful ("view-only", null, new Variant.boolean (false));
            view_only_action.activate.connect (() => toggle_view_only ());
            add_action (view_only_action);
            session_actions.add (view_only_action);
            var screenshot_action = new SimpleAction ("screenshot", null);
            screenshot_action.activate.connect (() => screenshot ());
            add_action (screenshot_action);
            session_actions.add (screenshot_action);
            var cad_action = new SimpleAction ("send-ctrl-alt-del", null);
            cad_action.activate.connect (() => {
                if (session != null) session.send_combo ({ Gdk.Key.Control_L, Gdk.Key.Alt_L, Gdk.Key.Delete });
            });
            add_action (cad_action);
            session_actions.add (cad_action);
            var cab_action = new SimpleAction ("send-ctrl-alt-backspace", null);
            cab_action.activate.connect (() => {
                if (session != null) session.send_combo ({ Gdk.Key.Control_L, Gdk.Key.Alt_L, Gdk.Key.BackSpace });
            });
            add_action (cab_action);
            session_actions.add (cab_action);

            store.changed.connect (rebuild);
            close_request.connect (() => {
                if (session != null) end_session ();
                return false;
            });
            rebuild ();
        }

        private Widget build_welcome () {
            var wp = new WelcomePage ();
            wp.app_icon_name = "dev.sinty.connections";
            wp.title = _("Connections");
            wp.subtitle = _("See and control a computer over VNC or RDP. Your connections are kept here.");
            wp.add_action ("computer", _("New Connection"), _("Enter the address of a computer"), () => edit_connection (null));
            wp.add_action ("folder-open", _("Open a Connection File"), _("Use a .rdp or .vnc file"), () => open_file ());
            return wp;
        }

        private Widget build_list () {
            grid = new FlowBox ();
            grid.selection_mode = SelectionMode.NONE;
            grid.activate_on_single_click = true;
            grid.homogeneous = true;
            grid.min_children_per_line = 1;
            grid.max_children_per_line = 5;
            grid.column_spacing = 20;
            grid.row_spacing = 24;
            grid.valign = Align.START;
            grid.halign = Align.CENTER;
            grid.margin_top = 24;
            grid.margin_bottom = 32;
            grid.margin_start = 32;
            grid.margin_end = 32;
            grid.set_filter_func ((child) => {
                if (filter == "") return true;
                var c = ((ConnectionCard) child).connection;
                return c.title ().down ().contains (filter) || c.host.down ().contains (filter) || c.username.down ().contains (filter);
            });
            grid.child_activated.connect ((child) => connect_to (((ConnectionCard) child).connection));
            var scroll = new ScrolledWindow ();
            scroll.hscrollbar_policy = PolicyType.NEVER;
            scroll.child = grid;
            apply_view_edge (scroll);
            return scroll;
        }

        private Widget build_session () {
            var overlay = new Overlay ();
            overlay.add_css_class ("conn-stage");
            display = new RemoteDisplay ();
            display.hexpand = true;
            display.vexpand = true;
            display_scroll = new ScrolledWindow ();
            display_scroll.child = display;
            overlay.child = display_scroll;

            status_box = new Box (Orientation.VERTICAL, 12);
            status_box.add_css_class ("conn-status");
            status_box.halign = Align.CENTER;
            status_box.valign = Align.CENTER;
            spinner = new Spinner ();
            spinner.set_size_request (32, 32);
            status_box.append (spinner);
            status_title = new Label ("");
            status_title.add_css_class ("title-3");
            status_title.wrap = true;
            status_title.justify = Justification.CENTER;
            status_box.append (status_title);
            status_detail = new Label ("");
            status_detail.add_css_class ("dim-label");
            status_detail.wrap = true;
            status_detail.max_width_chars = 44;
            status_detail.justify = Justification.CENTER;
            status_box.append (status_detail);
            var buttons = new Box (Orientation.HORIZONTAL, 12);
            buttons.halign = Align.CENTER;
            buttons.margin_top = 8;
            status_back = new Button.with_label (_("Cancel"));
            status_back.add_css_class ("pill");
            status_back.clicked.connect (() => disconnect_session ());
            buttons.append (status_back);
            status_primary = new Button.with_label (_("Try Again"));
            status_primary.add_css_class ("pill");
            status_primary.add_css_class ("suggested-action");
            status_primary.clicked.connect (() => {
                if (current != null) connect_to (current);
            });
            buttons.append (status_primary);
            status_box.append (buttons);
            overlay.add_overlay (status_box);
            return overlay;
        }

        private void show_page (string name) {
            stack.visible_child_name = name;
            bool live = name == "session";
            add_bubble.visible = !live;
            search_bubble.visible = name == "list";
            find_action.set_enabled (name == "list");
            foreach (var w in session_bubbles) w.visible = live && session != null && session.active;
            bool running = live && session != null && session.active;
            foreach (var a in session_actions) a.set_enabled (running);
            disconnect_action.set_enabled (live);
            if (running) view_only_action.set_state (new Variant.boolean (session.view_only));
        }

        private void rebuild () {
            Widget? child;
            while ((child = grid.get_first_child ()) != null) grid.remove (child);
            foreach (var c in store.sorted ()) {
                var card = new ConnectionCard (c);
                var click = new GestureClick ();
                click.button = 3;
                click.pressed.connect ((n, x, y) => card_menu (card, x, y));
                card.add_controller (click);
                var press = new GestureLongPress ();
                press.pressed.connect ((x, y) => card_menu (card, x, y));
                card.add_controller (press);
                grid.append (card);
            }
            if (stack.visible_child_name != "session") show_page (store.items.size == 0 ? "welcome" : "list");
        }

        private void card_menu (ConnectionCard card, double x, double y) {
            var c = card.connection;
            var menu = new ContextMenu (card);
            menu.add_item (_("Connect"), "media-playback-start-symbolic", () => connect_to (c));
            menu.add_item (_("Edit"), "document-edit-symbolic", () => edit_connection (c));
            menu.add_item (_("Duplicate"), "edit-copy-symbolic", () => {
                var d = c.copy ();
                d.id = "";
                d.name = _("%s (Copy)").printf (c.title ());
                d.last_used = 0;
                store.put (d);
            });
            menu.add_separator ();
            menu.add_item (_("Delete"), "user-trash-symbolic", () => confirm_delete (c), "destructive");
            menu.pointing_to = { (int) x, (int) y, 1, 1 };
            menu.closed.connect (() => Idle.add (() => {
                menu.unparent ();
                return Source.REMOVE;
            }));
            menu.popup ();
        }

        private void confirm_delete (Connection c) {
            var dlg = new ConfirmDialog ((Gtk.Application) application, _("Delete %s?").printf (c.title ()), "user-trash-symbolic",
                _("The connection and its saved password are removed."), _("Delete"), ConfirmDialog.ActionStyle.DESTRUCTIVE);
            dlg.transient_for = this;
            dlg.modal = true;
            dlg.response.connect ((r) => {
                if (r == ConfirmDialog.Response.PRIMARY) store.remove (c);
            });
            dlg.present ();
        }

        public void edit_connection (Connection? existing, string? initial_address = null) {
            bool is_new = existing == null;
            var c = is_new ? new Connection () : existing.copy ();
            string protocol = c.protocol;
            var dlg = new ConfirmDialog ((Gtk.Application) application, is_new ? _("New Connection") : _("Edit Connection"), null, null,
                is_new ? _("Connect") : _("Save"), ConfirmDialog.ActionStyle.SUGGESTED);
            dlg.transient_for = this;
            dlg.modal = true;
            dlg.set_default_size (440, 0);

            var proto = new SegmentedControl ();
            proto.add_option ("vnc", "VNC");
            proto.add_option ("rdp", "RDP");
            proto.set_active (protocol);
            proto.halign = Align.CENTER;
            dlg.custom_area.append (proto);

            var group = new PreferencesGroup ();
            var addr = new EntryRow (_("Address"));
            addr.text = initial_address ?? (is_new ? "" : c.address ());
            var name = new EntryRow (_("Name"));
            name.text = c.name;
            var user = new EntryRow (_("User Name"));
            user.text = c.username;
            var domain = new EntryRow (_("Domain"));
            domain.text = c.domain;
            group.add_row (addr);
            group.add_row (name);
            group.add_row (user);
            group.add_row (domain);
            dlg.custom_area.append (group);

            var options = new PreferencesGroup ();
            var view_only = new SwitchRow (_("View Only"), _("Watch without controlling the computer"), c.view_only);
            var resize = new SwitchRow (_("Match Window Size"), _("Resize the remote desktop to the window"), c.resize_remote);
            options.add_row (resize);
            options.add_row (view_only);
            dlg.custom_area.append (options);

            var hint = new Label ("");
            hint.add_css_class ("dim-label");
            hint.add_css_class ("caption");
            hint.wrap = true;
            hint.max_width_chars = 44;
            dlg.custom_area.append (hint);

            ulong guard = 0;
            Validator validate = () => {
                string t = addr.text.strip ();
                int scheme = t.index_of ("://");
                if (scheme > 0) {
                    string p = t.substring (0, scheme).down ();
                    if ((p == "vnc" || p == "rdp") && p != protocol) {
                        protocol = p;
                        SignalHandler.block (proto, guard);
                        proto.set_active (p);
                        SignalHandler.unblock (proto, guard);
                    }
                }
                domain.visible = protocol == "rdp";
                user.subtitle = protocol == "vnc" ? _("Only for servers that ask for one") : "";
                var a = Address.parse (t, protocol);
                dlg.primary_sensitive = a != null;
                if (t == "") hint.label = protocol == "vnc" ? _("For example 192.168.1.20, server:1 or vnc://server:5901") : _("For example office-pc, 10.0.0.5 or rdp://server:3389");
                else if (a == null) hint.label = _("This is not a valid address.");
                else hint.label = _("Connects to %s on port %d.").printf (a.host, a.port);
            };
            guard = proto.selected.connect ((n) => {
                protocol = n;
                string t = addr.text.strip ();
                int scheme = t.index_of ("://");
                if (scheme > 0) addr.text = n + t.substring (scheme);
                validate ();
            });
            addr.entry_changed.connect (() => validate ());
            addr.entry_activated.connect (() => {
                if (Address.parse (addr.text, protocol) != null) {
                    dlg.response (ConfirmDialog.Response.PRIMARY);
                    dlg.close_dialog ();
                }
            });
            validate ();

            dlg.response.connect ((r) => {
                if (r != ConfirmDialog.Response.PRIMARY) return;
                var a = Address.parse (addr.text, protocol);
                if (a == null) return;
                bool moved = a.host != c.host || a.port != c.port || a.protocol != c.protocol;
                c.protocol = a.protocol;
                c.host = a.host;
                c.port = a.port;
                if (moved) c.fingerprint = "";
                c.name = name.text.strip ();
                c.username = user.text.strip ();
                c.domain = c.protocol == "rdp" ? domain.text.strip () : "";
                c.view_only = view_only.active;
                c.resize_remote = resize.active;
                store.put (c);
                if (is_new) connect_to (c);
            });
            dlg.present ();
            addr.grab_focus ();
        }

        public void connect_to (Connection c) {
            if (current != c) {
                pending_password = null;
                remember_pending = false;
            }
            if (session != null) end_session ();
            current = c;
            c.last_used = new DateTime.now_utc ().to_unix ();
            store.put (c);
            show_status (true, _("Connecting to %s").printf (c.title ()), c.address (), false);
            show_page ("session");
            Store.lookup_password.begin (c.id, (o, res) => {
                string? pw = Store.lookup_password.end (res);
                if (current != c) return;
                if ((pw == null || pw == "") && pending_password != null) pw = pending_password;
                start_session (c, pw ?? "");
            });
        }

        private void start_session (Connection c, string password) {
            int scale = get_scale_factor ();
            int w = int.max (display_scroll.get_width (), 640) * scale;
            int h = int.max (display_scroll.get_height (), 480) * scale;
            RemoteSession s;
            if (c.protocol == "rdp") s = new RdpSession (c.host, c.port, w, h);
            else s = new VncSession (c.host, c.port);
            s.username = c.username;
            s.domain = c.domain;
            s.password = password;
            s.trusted_fingerprint = c.fingerprint;
            s.view_only = c.view_only;
            session = s;
            s.credentials_needed.connect ((want_user, reason) => {
                if (session == s) ask_credentials (s, want_user, reason);
            });
            s.ready.connect (() => {
                if (session != s) return;
                if (remember_pending && pending_password != null) Store.store_password.begin (c, pending_password);
                remember_pending = false;
                pending_password = null;
                status_box.visible = false;
                display.session = s;
                display.fit = c.fit;
                display.resize_remote = c.resize_remote;
                sync_fit ();
                show_page ("session");
                display.grab_focus ();
                inhibit_shortcuts (true);
                push_clipboard ();
            });
            s.remote_clipboard.connect ((text) => {
                last_clipboard = text;
                display.get_clipboard ().set_text (text);
            });
            s.bell.connect (() => display.error_bell ());
            s.closed.connect ((err) => {
                if (session != s) return;
                session_closed (s, err);
            });
            s.start ();
        }

        private void session_closed (RemoteSession s, Error? err) {
            inhibit_shortcuts (false);
            save_thumbnail (s);
            display.session = null;
            session = null;
            if (err == null) {
                if (fullscreened) unfullscreen ();
                show_page (store.items.size == 0 ? "welcome" : "list");
                return;
            }
            if (err is SessionError.UNTRUSTED && s.pending_fingerprint != "") {
                ask_trust (current, s.pending_fingerprint);
                return;
            }
            if (err is SessionError.AUTH_FAILED && current != null) {
                Store.forget_password.begin (current.id);
                pending_password = null;
                remember_pending = false;
            }
            string title = _("Could Not Connect");
            if (err is SessionError.AUTH_FAILED) title = _("Wrong Password");
            else if (s.width > 0 && s.texture != null) title = _("Connection Lost");
            show_status (false, title, err.message, true);
            show_page ("session");
        }

        private void show_status (bool busy, string title, string detail, bool can_retry) {
            status_box.visible = true;
            spinner.spinning = busy;
            spinner.visible = busy;
            status_title.label = title;
            status_detail.label = detail;
            status_primary.visible = can_retry;
            status_back.label = can_retry ? _("Back") : _("Cancel");
        }

        private void end_session () {
            var s = session;
            session = null;
            inhibit_shortcuts (false);
            if (s == null) return;
            save_thumbnail (s);
            display.release_all ();
            display.session = null;
            s.stop ();
        }

        private void disconnect_session () {
            end_session ();
            current = null;
            if (fullscreened) unfullscreen ();
            show_page (store.items.size == 0 ? "welcome" : "list");
        }

        private void ask_credentials (RemoteSession s, bool want_user, string? reason) {
            var c = current;
            string title = c != null ? _("Sign In to %s").printf (c.title ()) : _("Sign In");
            var dlg = new ConfirmDialog ((Gtk.Application) application, title, "dialog-password-symbolic",
                reason ?? (want_user ? _("Enter the user name and password for the remote computer.") : _("Enter the password for the remote computer.")),
                _("Sign In"), ConfirmDialog.ActionStyle.SUGGESTED);
            dlg.transient_for = this;
            dlg.modal = true;
            var group = new PreferencesGroup ();
            var user = new EntryRow (_("User Name"));
            user.text = s.username;
            var domain = new EntryRow (_("Domain"));
            domain.text = s.domain;
            var pass = new PasswordRow (_("Password"));
            var remember = new SwitchRow (_("Remember Password"), null, true);
            if (want_user) group.add_row (user);
            if (want_user && s is RdpSession) group.add_row (domain);
            group.add_row (pass);
            group.add_row (remember);
            dlg.custom_area.append (group);
            dlg.primary_sensitive = false;
            pass.entry_changed.connect (() => dlg.primary_sensitive = pass.text != "");
            pass.entry_activated.connect (() => {
                if (pass.text == "") return;
                dlg.response (ConfirmDialog.Response.PRIMARY);
                dlg.close_dialog ();
            });
            show_status (true, _("Waiting for Sign In"), c != null ? c.address () : "", false);
            dlg.response.connect ((r) => {
                if (session != s) return;
                if (r != ConfirmDialog.Response.PRIMARY) {
                    disconnect_session ();
                    return;
                }
                if (c != null && want_user && (user.text.strip () != c.username || domain.text.strip () != c.domain)) {
                    c.username = user.text.strip ();
                    c.domain = domain.text.strip ();
                    store.put (c);
                }
                remember_pending = remember.active;
                pending_password = pass.text;
                show_status (true, _("Connecting to %s").printf (c != null ? c.title () : s.host), c != null ? c.address () : "", false);
                s.provide_credentials (user.text.strip () != "" ? user.text.strip () : s.username, pass.text, domain.text.strip ());
            });
            dlg.present ();
            if (want_user && s.username == "") user.grab_focus ();
            else pass.grab_focus ();
        }

        private void ask_trust (Connection? c, string fingerprint) {
            if (c == null) return;
            bool changed = c.fingerprint != "";
            var dlg = new ConfirmDialog ((Gtk.Application) application,
                changed ? _("The Identity of %s Has Changed").printf (c.title ()) : _("Trust %s?").printf (c.title ()),
                changed ? "dialog-warning-symbolic" : "security-medium-symbolic",
                changed ? _("The remote computer shows a different certificate than last time. Only continue if you know why it changed.") : _("This is the first connection to this computer. Check that the fingerprint matches the one shown on the remote computer."),
                _("Trust and Connect"), changed ? ConfirmDialog.ActionStyle.DESTRUCTIVE : ConfirmDialog.ActionStyle.SUGGESTED);
            dlg.transient_for = this;
            dlg.modal = true;
            var fp = new Label (fingerprint);
            fp.add_css_class ("monospace");
            fp.add_css_class ("conn-fingerprint");
            fp.wrap = true;
            fp.wrap_mode = Pango.WrapMode.CHAR;
            fp.max_width_chars = 36;
            fp.selectable = true;
            fp.justify = Justification.CENTER;
            dlg.custom_area.append (fp);
            show_status (false, _("Waiting for Confirmation"), c.address (), false);
            dlg.response.connect ((r) => {
                if (r != ConfirmDialog.Response.PRIMARY) {
                    disconnect_session ();
                    return;
                }
                c.fingerprint = fingerprint;
                store.put (c);
                connect_to (c);
            });
            dlg.present ();
        }

        private void toggle_fit () {
            if (current == null) return;
            current.fit = !current.fit;
            store.put (current);
            display.fit = current.fit;
            sync_fit ();
        }

        private void toggle_view_only () {
            if (session == null) return;
            var s = session;
            s.view_only = !s.view_only;
            if (current != null) {
                current.view_only = s.view_only;
                store.put (current);
            }
            view_only_action.set_state (new Variant.boolean (s.view_only));
            show_toast (s.view_only ? _("View only") : _("You can control the computer"));
        }

        private void sync_fit () {
            bool fit = display.fit;
            fit_action.set_state (new Variant.boolean (fit));
            fit_bubble.icon_name = fit ? "zoom-original-symbolic" : "zoom-fit-best-symbolic";
            fit_bubble.tooltip_text = fit ? _("Show at Original Size") : _("Fit to Window");
            display_scroll.hscrollbar_policy = fit ? PolicyType.NEVER : PolicyType.AUTOMATIC;
            display_scroll.vscrollbar_policy = fit ? PolicyType.NEVER : PolicyType.AUTOMATIC;
        }

        private void keys_menu (Button? anchor) {
            if (anchor == null || session == null) return;
            var s = session;
            var menu = new ContextMenu (anchor);
            menu.add_item ("Ctrl+Alt+Del", null, () => s.send_combo ({ Gdk.Key.Control_L, Gdk.Key.Alt_L, Gdk.Key.Delete }));
            menu.add_item ("Ctrl+Alt+Backspace", null, () => s.send_combo ({ Gdk.Key.Control_L, Gdk.Key.Alt_L, Gdk.Key.BackSpace }));
            menu.add_item (_("Super"), null, () => s.send_combo ({ Gdk.Key.Super_L }));
            menu.add_item (_("Print Screen"), null, () => s.send_combo ({ Gdk.Key.Print }));
            menu.add_item ("Alt+Tab", null, () => s.send_combo ({ Gdk.Key.Alt_L, Gdk.Key.Tab }));
            menu.add_item ("Alt+F4", null, () => s.send_combo ({ Gdk.Key.Alt_L, Gdk.Key.F4 }));
            menu.add_separator ();
            menu.add_item (s.view_only ? _("Allow Control") : _("View Only"), s.view_only ? "input-mouse-symbolic" : "view-reveal-symbolic", () => toggle_view_only ());
            menu.closed.connect (() => Idle.add (() => {
                menu.unparent ();
                return Source.REMOVE;
            }));
            menu.popup ();
        }

        private void inhibit_shortcuts (bool on) {
            var toplevel = get_surface () as Gdk.Toplevel;
            if (toplevel == null || on == inhibiting) return;
            inhibiting = on;
            if (on) toplevel.inhibit_system_shortcuts (null);
            else toplevel.restore_system_shortcuts ();
        }

        private void push_clipboard () {
            if (session == null || !session.active) return;
            var s = session;
            display.get_clipboard ().read_text_async.begin (null, (o, res) => {
                try {
                    string? text = display.get_clipboard ().read_text_async.end (res);
                    if (text == null || text == last_clipboard || session != s) return;
                    last_clipboard = text;
                    s.send_clipboard (text);
                } catch (Error e) {
                }
            });
        }

        private Gdk.Pixbuf? pixbuf_of (Gdk.Texture tex) {
            var dl = new Gdk.TextureDownloader (tex);
            dl.set_format (Gdk.MemoryFormat.R8G8B8);
            size_t stride;
            var bytes = dl.download_bytes (out stride);
            return new Gdk.Pixbuf.from_bytes (bytes, Gdk.Colorspace.RGB, false, 8, tex.width, tex.height, (int) stride);
        }

        private void save_thumbnail (RemoteSession s) {
            if (current == null || s.texture == null) return;
            var pix = pixbuf_of (s.texture);
            if (pix == null) return;
            int w = 464;
            int h = (int) Math.round ((double) pix.height * w / pix.width);
            var small = pix.scale_simple (w, int.max (h, 1), Gdk.InterpType.BILINEAR);
            string path = Store.thumbnail_path (current.id);
            DirUtils.create_with_parents (Path.get_dirname (path), 0700);
            try {
                small.savev (path, "png", {}, {});
            } catch (Error e) {
                warning ("connections: %s", e.message);
            }
            rebuild ();
        }

        private void screenshot () {
            if (session == null || session.texture == null) return;
            string dir = Path.build_filename (Environment.get_user_special_dir (UserDirectory.PICTURES) ?? Environment.get_home_dir (), "Screenshots");
            DirUtils.create_with_parents (dir, 0755);
            string name = current != null ? current.title ().replace ("/", "-") : session.host;
            string path = Path.build_filename (dir, "%s %s.png".printf (name, new DateTime.now_local ().format ("%Y-%m-%d %H-%M-%S")));
            if (session.texture.save_to_png (path)) show_toast (_("Screenshot saved in %s").printf (Path.get_basename (dir)));
            else show_toast (_("The screenshot could not be saved"));
        }

        private void show_toast (string text) {
            if (toast == null) {
                toast = new Label ("");
                toast.add_css_class ("conn-toast");
                toast.halign = Align.CENTER;
                toast.valign = Align.END;
                toast.margin_bottom = 28;
                toast.can_target = false;
                var overlay = (Overlay) stack.get_child_by_name ("session");
                overlay.add_overlay (toast);
            }
            toast.label = text;
            toast.visible = true;
            if (toast_id != 0) Source.remove (toast_id);
            toast_id = Timeout.add (2500, () => {
                toast_id = 0;
                toast.visible = false;
                return Source.REMOVE;
            });
        }

        public void open_file () {
            var dialog = new FileDialog ();
            dialog.title = _("Open a Connection File");
            var filters = new GLib.ListStore (typeof (FileFilter));
            var f = new FileFilter ();
            f.name = _("Connection Files");
            f.add_suffix ("rdp");
            f.add_suffix ("vnc");
            f.add_mime_type ("application/x-rdp");
            filters.append (f);
            dialog.filters = filters;
            dialog.open.begin (this, null, (o, res) => {
                try {
                    var file = dialog.open.end (res);
                    if (file != null) open_target (file);
                } catch (Error e) {
                }
            });
        }

        public void open_target (File file) {
            string uri = file.get_uri ();
            string scheme = file.get_uri_scheme () ?? "";
            Connection? c = null;
            if (scheme == "vnc" || scheme == "rdp") {
                var a = Address.parse (uri);
                if (a != null) c = find_or_make (a, "", "");
            } else {
                c = ConnectionFile.load (file, store);
            }
            if (c == null) {
                var dlg = new ConfirmDialog ((Gtk.Application) application, _("Could Not Open"), "dialog-error-symbolic",
                    _("%s is not a connection this app understands.").printf (file.get_basename () ?? uri), _("OK"), ConfirmDialog.ActionStyle.SUGGESTED);
                dlg.transient_for = this;
                dlg.present ();
                return;
            }
            connect_to (c);
        }

        public Connection find_or_make (Address a, string username, string domain) {
            foreach (var c in store.items) {
                if (c.protocol == a.protocol && c.host == a.host && c.port == a.port && (username == "" || c.username == username)) return c;
            }
            var c = new Connection ();
            c.protocol = a.protocol;
            c.host = a.host;
            c.port = a.port;
            c.username = username;
            c.domain = domain;
            store.put (c);
            return c;
        }
    }

    namespace ConnectionFile {
        public Connection? load (File file, Store store) {
            string text;
            try {
                uint8[] data;
                file.load_contents (null, out data, null);
                text = (string) data;
                if (data.length >= 2 && data[0] == 0xFF && data[1] == 0xFE) {
                    text = convert ((string) data[2:data.length], data.length - 2, "UTF-8", "UTF-16LE");
                }
            } catch (Error e) {
                return null;
            }
            string? name = file.get_basename ();
            if (name != null && name.down ().has_suffix (".vnc")) return load_vnc (text, store);
            return load_rdp (text, store);
        }

        private Connection? load_rdp (string text, Store store) {
            string address = "", username = "", domain = "";
            int port = 0;
            foreach (string raw in text.split ("\n")) {
                string line = raw.strip ();
                string[] parts = line.split (":", 3);
                if (parts.length < 3) continue;
                string key = parts[0].down ();
                if (key == "full address") address = parts[2];
                else if (key == "server port") port = int.parse (parts[2]);
                else if (key == "username") username = parts[2];
                else if (key == "domain") domain = parts[2];
            }
            if (address == "") return null;
            if (username.contains ("\\") && domain == "") {
                string[] du = username.split ("\\", 2);
                domain = du[0];
                username = du[1];
            }
            var a = Address.parse (address, "rdp");
            if (a == null) return null;
            a.protocol = "rdp";
            if (port > 0 && !address.contains (":")) a.port = port;
            return find_in (store, a, username, domain);
        }

        private Connection? load_vnc (string text, Store store) {
            string host = "";
            int port = 0;
            foreach (string raw in text.split ("\n")) {
                string line = raw.strip ();
                int eq = line.index_of ("=");
                if (eq <= 0) continue;
                string key = line.substring (0, eq).strip ().down ();
                string val = line.substring (eq + 1).strip ();
                if (key == "host") host = val;
                else if (key == "port") port = int.parse (val);
            }
            if (host == "") return null;
            var a = Address.parse (host, "vnc");
            if (a == null) return null;
            if (port > 0 && !host.contains (":")) a.port = port;
            return find_in (store, a, "", "");
        }

        private Connection find_in (Store store, Address a, string username, string domain) {
            foreach (var c in store.items) {
                if (c.protocol == a.protocol && c.host == a.host && c.port == a.port) return c;
            }
            var c = new Connection ();
            c.protocol = a.protocol;
            c.host = a.host;
            c.port = a.port;
            c.username = username;
            c.domain = domain;
            store.put (c);
            return c;
        }
    }
}
