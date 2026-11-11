namespace Singularity.Apps.Connections {

    internal class ConnectionsIntents : Object {

        private static string text(Json.Object args, string key) {
            return args.has_member(key) ? args.get_string_member(key).strip() : "";
        }

        private static Connection find(ConnectionsApp app, string wanted) throws Error {
            if (wanted == "") throw new IOError.INVALID_ARGUMENT("give the connection id or name from connections_list");
            var c = app.store.find(wanted);
            if (c != null) return c;
            string w = wanted.casefold();
            foreach (var x in app.store.items) if (x.title().casefold() == w || x.address().casefold() == w || x.host.casefold() == w) return x;
            Connection? hit = null;
            foreach (var x in app.store.items) {
                if (!x.title().casefold().contains(w)) continue;
                if (hit != null) throw new IOError.INVALID_ARGUMENT("%s matches more than one connection; use the id", wanted);
                hit = x;
            }
            if (hit != null) return hit;
            throw new IOError.NOT_FOUND("no saved connection %s; see connections_list", wanted);
        }

        private static void entry(Json.Builder b, Connection c) {
            b.begin_object();
            b.set_member_name("id").add_string_value(c.id);
            b.set_member_name("name").add_string_value(c.title());
            b.set_member_name("protocol").add_string_value(c.protocol);
            b.set_member_name("address").add_string_value(c.address());
            if (c.username != "") b.set_member_name("username").add_string_value(c.username);
            if (c.domain != "") b.set_member_name("domain").add_string_value(c.domain);
            if (c.view_only) b.set_member_name("view_only").add_boolean_value(true);
            if (c.last_used > 0) b.set_member_name("last_used").add_string_value(new DateTime.from_unix_local(c.last_used).format_iso8601());
            b.end_object();
        }

        private static Connection? saved(string id) {
            var fresh = new Store();
            return fresh.find(id);
        }

        private static ConnectionsWindow? live_window(ConnectionsApp app) {
            foreach (var w in app.get_windows()) {
                var cw = w as ConnectionsWindow;
                if (cw != null && cw.session_connection() != null) return cw;
            }
            return null;
        }

        private static void apply(Connection c, Json.Object args) throws Error {
            if (text(args, "address") != "") {
                var a = Address.parse(text(args, "address"), text(args, "protocol") == "rdp" ? "rdp" : c.protocol);
                if (a == null) throw new IOError.INVALID_ARGUMENT("%s is not a remote desktop address", text(args, "address"));
                c.protocol = a.protocol;
                c.host = a.host;
                c.port = a.port;
            } else if (text(args, "protocol") != "") {
                string p = text(args, "protocol");
                if (p != "vnc" && p != "rdp") throw new IOError.INVALID_ARGUMENT("protocol is vnc or rdp");
                if (c.port == Address.default_port(c.protocol)) c.port = Address.default_port(p);
                c.protocol = p;
            }
            if (args.has_member("name")) c.name = text(args, "name");
            if (args.has_member("username")) c.username = text(args, "username");
            if (args.has_member("domain")) c.domain = text(args, "domain");
            if (args.has_member("view_only")) c.view_only = args.get_boolean_member("view_only");
        }

        private static async void open(ConnectionsApp app, Json.Object args, owned Singularity.AppIntentReply reply) {
            app.hold();
            try {
                var c = find(app, text(args, "connection"));
                var w = app.window();
                w.present();
                w.connect_to(c);
                for (int i = 0; i < 60; i++) {
                    if (w.session_live() || w.session_error != "") break;
                    Timeout.add(250, open.callback);
                    yield;
                }
                var b = new Json.Builder();
                b.begin_object();
                b.set_member_name("connection").add_string_value(c.title());
                if (w.session_live()) {
                    b.set_member_name("state").add_string_value("connected");
                } else if (w.session_connection() != null) {
                    b.set_member_name("state").add_string_value("connecting");
                    b.set_member_name("note").add_string_value("the window may be asking the person for a password or to trust the computer");
                } else {
                    b.set_member_name("state").add_string_value("failed");
                    if (w.session_error != "") b.set_member_name("error").add_string_value(w.session_error);
                }
                b.set_member_name("undo").add_string_value("connections_disconnect");
                b.end_object();
                reply(b.get_root(), null);
            } catch (Error e) {
                reply(null, e);
            } finally {
                app.release();
            }
        }

        internal static void install(ConnectionsApp app) {
            var agent = app.agent;
            agent.add_intent("connections_list", "The saved remote desktops (VNC and RDP), most recently used first, and which one is open now.",
                "{\"type\":\"object\",\"properties\":{}}", Singularity.AppIntentRisk.READ, (args) => {
                    var b = new Json.Builder();
                    b.begin_object();
                    b.set_member_name("connections").begin_array();
                    foreach (var c in app.store.sorted()) entry(b, c);
                    b.end_array();
                    var w = live_window(app);
                    if (w != null) {
                        b.set_member_name("open").add_string_value(w.session_connection().id);
                        b.set_member_name("state").add_string_value(w.session_live() ? "connected" : "connecting");
                    }
                    b.end_object();
                    return b.get_root();
                });
            agent.add_intent("connections_add", "Save a remote desktop. The address is host, host:port or vnc:// or rdp:// form. Passwords are never given here: the window asks the person when connecting.",
                "{\"type\":\"object\",\"properties\":{\"address\":{\"type\":\"string\"},\"protocol\":{\"type\":\"string\",\"enum\":[\"vnc\",\"rdp\"]},\"name\":{\"type\":\"string\"},\"username\":{\"type\":\"string\"},\"domain\":{\"type\":\"string\"},\"view_only\":{\"type\":\"boolean\"}},\"required\":[\"address\"]}",
                Singularity.AppIntentRisk.UNDOABLE, (args) => {
                    var c = new Connection();
                    c.protocol = text(args, "protocol") == "rdp" ? "rdp" : "vnc";
                    apply(c, args);
                    foreach (var x in app.store.items) {
                        if (x.protocol == c.protocol && x.host == c.host && x.port == c.port && x.username == c.username)
                            throw new IOError.EXISTS("%s is already saved as %s", c.address(), x.title());
                    }
                    app.store.put(c);
                    if (saved(c.id) == null) throw new IOError.FAILED("the connection was not saved");
                    var b = new Json.Builder();
                    b.begin_object();
                    b.set_member_name("saved");
                    entry(b, c);
                    b.set_member_name("undo").add_string_value("connections_remove with connection " + c.id);
                    b.end_object();
                    return b.get_root();
                });
            agent.add_intent("connections_edit", "Change a saved remote desktop: its name, address, protocol, user name, domain or view only.",
                "{\"type\":\"object\",\"properties\":{\"connection\":{\"type\":\"string\"},\"address\":{\"type\":\"string\"},\"protocol\":{\"type\":\"string\",\"enum\":[\"vnc\",\"rdp\"]},\"name\":{\"type\":\"string\"},\"username\":{\"type\":\"string\"},\"domain\":{\"type\":\"string\"},\"view_only\":{\"type\":\"boolean\"}},\"required\":[\"connection\"]}",
                Singularity.AppIntentRisk.UNDOABLE, (args) => {
                    var c = find(app, text(args, "connection"));
                    var before = c.copy();
                    var edited = c.copy();
                    apply(edited, args);
                    app.store.put(edited);
                    var check = saved(edited.id);
                    if (check == null || check.address() != edited.address() || check.title() != edited.title()) throw new IOError.FAILED("the change was not saved");
                    var b = new Json.Builder();
                    b.begin_object();
                    b.set_member_name("saved");
                    entry(b, edited);
                    b.set_member_name("undo").add_string_value("connections_edit with connection %s, name \"%s\", address %s://%s, username \"%s\", domain \"%s\", view_only %s".printf(
                        before.id, before.name, before.protocol, before.address(), before.username, before.domain, before.view_only ? "true" : "false"));
                    b.end_object();
                    return b.get_root();
                });
            agent.add_intent("connections_remove", "Delete a saved remote desktop and the password remembered for it.",
                "{\"type\":\"object\",\"properties\":{\"connection\":{\"type\":\"string\"}},\"required\":[\"connection\"]}",
                Singularity.AppIntentRisk.IRREVERSIBLE, (args) => {
                    var c = find(app, text(args, "connection"));
                    var w = live_window(app);
                    if (w != null && w.session_connection().id == c.id) throw new IOError.BUSY("%s is open; disconnect first", c.title());
                    app.store.remove(c);
                    if (saved(c.id) != null) throw new IOError.FAILED("%s is still saved", c.title());
                    var b = new Json.Builder();
                    b.begin_object();
                    b.set_member_name("removed").add_string_value(c.title());
                    b.set_member_name("address").add_string_value(c.protocol + "://" + c.address());
                    b.end_object();
                    return b.get_root();
                });
            agent.add_async_intent("connections_open", "Open a saved remote desktop in the Connections window. The person sees it and enters any password themselves.",
                "{\"type\":\"object\",\"properties\":{\"connection\":{\"type\":\"string\"}},\"required\":[\"connection\"]}",
                Singularity.AppIntentRisk.UNDOABLE, (args, reply) => {
                    open.begin(app, args, (owned) reply);
                });
            agent.add_intent("connections_disconnect", "Close the remote desktop that is open now.",
                "{\"type\":\"object\",\"properties\":{}}", Singularity.AppIntentRisk.UNDOABLE, (args) => {
                    var w = live_window(app);
                    if (w == null) throw new IOError.NOT_FOUND("no remote desktop is open");
                    var c = w.session_connection();
                    w.activate_action_variant("win.disconnect", null);
                    if (w.session_connection() != null) throw new IOError.FAILED("%s did not close", c.title());
                    var b = new Json.Builder();
                    b.begin_object();
                    b.set_member_name("disconnected").add_string_value(c.title());
                    b.set_member_name("undo").add_string_value("connections_open with connection " + c.id);
                    b.end_object();
                    return b.get_root();
                });
        }
    }
}
