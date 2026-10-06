namespace Singularity.Apps.Connections {

    public class Address : Object {
        public string protocol = "";
        public string host = "";
        public int port = 0;

        public static int default_port (string protocol) {
            return protocol == "rdp" ? 3389 : 5900;
        }

        public static Address? parse (string text, string fallback_protocol = "vnc") {
            string s = text.strip ();
            if (s == "") return null;
            var a = new Address ();
            a.protocol = fallback_protocol;
            int scheme = s.index_of ("://");
            if (scheme > 0) {
                string p = s.substring (0, scheme).down ();
                if (p != "vnc" && p != "rdp") return null;
                a.protocol = p;
                s = s.substring (scheme + 3);
            }
            if (s.has_suffix ("/")) s = s.substring (0, s.length - 1);
            if (s.has_prefix ("[")) {
                int close = s.index_of ("]");
                if (close < 0) return null;
                a.host = s.substring (1, close - 1);
                string rest = s.substring (close + 1);
                if (rest.has_prefix (":")) a.port = int.parse (rest.substring (1));
            } else if (s.index_of ("::") > 0 && s.index_of ("::") == s.last_index_of (":") - 1) {
                int dc = s.index_of ("::");
                a.host = s.substring (0, dc);
                a.port = int.parse (s.substring (dc + 2));
            } else if (s.index_of (":") > 0 && s.index_of (":") == s.last_index_of (":")) {
                int c = s.index_of (":");
                a.host = s.substring (0, c);
                string rest = s.substring (c + 1);
                int n = int.parse (rest);
                if (rest == "" || n.to_string () != rest) return null;
                a.port = a.protocol == "vnc" && n >= 0 && n < 100 ? 5900 + n : n;
            } else {
                a.host = s;
            }
            if (a.host == "" || a.host.contains ("/") || a.host.contains (" ")) return null;
            if (a.port <= 0) a.port = default_port (a.protocol);
            if (a.port > 65535) return null;
            return a;
        }

        public string to_display () {
            string h = host.contains (":") ? "[" + host + "]" : host;
            if (port == default_port (protocol)) return h;
            return "%s:%d".printf (h, port);
        }
    }

    public class Connection : Object {
        public string id { get; set; default = ""; }
        public string name { get; set; default = ""; }
        public string protocol { get; set; default = "vnc"; }
        public string host { get; set; default = ""; }
        public int port { get; set; default = 5900; }
        public string username { get; set; default = ""; }
        public string domain { get; set; default = ""; }
        public bool view_only { get; set; }
        public bool fit { get; set; default = true; }
        public bool resize_remote { get; set; default = true; }
        public string fingerprint { get; set; default = ""; }
        public int64 last_used { get; set; }

        public string title () {
            if (name != "") return name;
            var a = new Address ();
            a.host = host;
            a.port = port;
            a.protocol = protocol;
            return a.to_display ();
        }

        public string address () {
            var a = new Address ();
            a.host = host;
            a.port = port;
            a.protocol = protocol;
            return a.to_display ();
        }

        public Connection copy () {
            var c = new Connection ();
            c.id = id;
            c.name = name;
            c.protocol = protocol;
            c.host = host;
            c.port = port;
            c.username = username;
            c.domain = domain;
            c.view_only = view_only;
            c.fit = fit;
            c.resize_remote = resize_remote;
            c.fingerprint = fingerprint;
            c.last_used = last_used;
            return c;
        }

        public Json.Node to_json () {
            var b = new Json.Builder ();
            b.begin_object ();
            b.set_member_name ("id").add_string_value (id);
            b.set_member_name ("name").add_string_value (name);
            b.set_member_name ("protocol").add_string_value (protocol);
            b.set_member_name ("host").add_string_value (host);
            b.set_member_name ("port").add_int_value (port);
            b.set_member_name ("username").add_string_value (username);
            b.set_member_name ("domain").add_string_value (domain);
            b.set_member_name ("view_only").add_boolean_value (view_only);
            b.set_member_name ("fit").add_boolean_value (fit);
            b.set_member_name ("resize_remote").add_boolean_value (resize_remote);
            b.set_member_name ("fingerprint").add_string_value (fingerprint);
            b.set_member_name ("last_used").add_int_value (last_used);
            b.end_object ();
            return b.get_root ();
        }

        public static Connection? from_json (Json.Object o) {
            if (!o.has_member ("host")) return null;
            var c = new Connection ();
            c.id = o.get_string_member_with_default ("id", Uuid.string_random ());
            c.name = o.get_string_member_with_default ("name", "");
            c.protocol = o.get_string_member_with_default ("protocol", "vnc") == "rdp" ? "rdp" : "vnc";
            c.host = o.get_string_member ("host");
            c.port = (int) o.get_int_member_with_default ("port", Address.default_port (c.protocol));
            c.username = o.get_string_member_with_default ("username", "");
            c.domain = o.get_string_member_with_default ("domain", "");
            c.view_only = o.get_boolean_member_with_default ("view_only", false);
            c.fit = o.get_boolean_member_with_default ("fit", true);
            c.resize_remote = o.get_boolean_member_with_default ("resize_remote", true);
            c.fingerprint = o.get_string_member_with_default ("fingerprint", "");
            c.last_used = o.get_int_member_with_default ("last_used", 0);
            return c;
        }
    }

    public class Store : Object {
        public Gee.ArrayList<Connection> items = new Gee.ArrayList<Connection> ();
        private string path;
        public signal void changed ();

        private static Secret.Schema schema () {
            return new Secret.Schema ("dev.sinty.connections", Secret.SchemaFlags.NONE, "id", Secret.SchemaAttributeType.STRING);
        }

        public Store (string? file = null) {
            path = file ?? Path.build_filename (Environment.get_user_config_dir (), "singularity", "connections.json");
            load ();
        }

        public static string thumbnail_path (string id) {
            return Path.build_filename (Environment.get_user_cache_dir (), "singularity-connections", id + ".png");
        }

        private void load () {
            items.clear ();
            if (!FileUtils.test (path, FileTest.EXISTS)) return;
            try {
                var parser = new Json.Parser ();
                parser.load_from_file (path);
                var root = parser.get_root ();
                if (root == null || root.get_node_type () != Json.NodeType.ARRAY) return;
                foreach (var node in root.get_array ().get_elements ()) {
                    if (node.get_node_type () != Json.NodeType.OBJECT) continue;
                    var c = Connection.from_json (node.get_object ());
                    if (c != null) items.add (c);
                }
            } catch (Error e) {
                warning ("connections: %s", e.message);
            }
        }

        public void save () {
            var arr = new Json.Array ();
            foreach (var c in items) arr.add_element (c.to_json ());
            var root = new Json.Node (Json.NodeType.ARRAY);
            root.set_array (arr);
            var gen = new Json.Generator ();
            gen.pretty = true;
            gen.set_root (root);
            try {
                DirUtils.create_with_parents (Path.get_dirname (path), 0700);
                FileUtils.set_contents (path, gen.to_data (null));
            } catch (Error e) {
                warning ("connections: %s", e.message);
            }
            changed ();
        }

        public Connection? find (string id) {
            foreach (var c in items) if (c.id == id) return c;
            return null;
        }

        public void put (Connection c) {
            if (c.id == "") c.id = Uuid.string_random ();
            for (int i = 0; i < items.size; i++) {
                if (items[i].id == c.id) {
                    items[i] = c;
                    save ();
                    return;
                }
            }
            items.add (c);
            save ();
        }

        public void remove (Connection c) {
            for (int i = 0; i < items.size; i++) {
                if (items[i].id == c.id) {
                    items.remove_at (i);
                    break;
                }
            }
            FileUtils.remove (thumbnail_path (c.id));
            forget_password.begin (c.id);
            save ();
        }

        public Gee.List<Connection> sorted () {
            var list = new Gee.ArrayList<Connection> ();
            list.add_all (items);
            list.sort ((a, b) => {
                if (a.last_used != b.last_used) return a.last_used > b.last_used ? -1 : 1;
                return a.title ().collate (b.title ());
            });
            return list;
        }

        public static async string? lookup_password (string id) {
            try {
                return yield Secret.password_lookup (schema (), null, "id", id);
            } catch (Error e) {
                return null;
            }
        }

        public static async void store_password (Connection c, string password) {
            try {
                yield Secret.password_store (schema (), Secret.COLLECTION_DEFAULT, _("Remote desktop password for %s").printf (c.title ()), password, null, "id", c.id);
            } catch (Error e) {
                warning ("connections: %s", e.message);
            }
        }

        public static async void forget_password (string id) {
            try {
                yield Secret.password_clear (schema (), null, "id", id);
            } catch (Error e) {
            }
        }
    }
}
