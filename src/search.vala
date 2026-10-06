namespace Singularity.Apps.Connections {

    public class ConnectionsSearch : Singularity.SearchProviderService {
        private ConnectionsApp app;

        public ConnectionsSearch (ConnectionsApp app) {
            this.app = app;
        }

        private Store store () {
            if (app.store == null) app.store = new Store ();
            return app.store;
        }

        private static bool matches (Connection c, string[] terms) {
            string haystack = (c.name + " " + c.host + " " + c.protocol).down ();
            foreach (string t in terms) {
                if (!haystack.contains (t.down ())) return false;
            }
            return true;
        }

        private string[] find (string[] terms, string[]? within) {
            string[] ids = {};
            foreach (var c in store ().sorted ()) {
                if (within != null && !(c.id in within)) continue;
                if (matches (c, terms)) ids += c.id;
            }
            return ids;
        }

        public override async string[] get_initial_results (string[] terms, Cancellable? cancellable) throws Error {
            return find (terms, null);
        }

        public override async string[] get_subsearch_results (string[] previous, string[] terms, Cancellable? cancellable) throws Error {
            return find (terms, previous);
        }

        public override async Singularity.SearchResultMeta[] get_result_metas (string[] ids, Cancellable? cancellable) throws Error {
            Singularity.SearchResultMeta[] metas = {};
            foreach (string id in ids) {
                var c = store ().find (id);
                if (c == null) continue;
                var meta = new Singularity.SearchResultMeta (id, c.title ());
                meta.description = "%s, %s".printf (c.address (), c.protocol.up ());
                meta.icon = new ThemedIcon ("network-server");
                meta.add_action ("connect", _("Connect"), "network-transmit-receive-symbolic");
                metas += meta;
            }
            return metas;
        }

        public override async Singularity.SearchActivationReply? activate_result (string id, string[] terms, uint32 timestamp) throws Error {
            app.connect_saved (id);
            return null;
        }

        public override async Singularity.SearchActivationReply? activate_action (string id, string action_id, string[] terms, uint32 timestamp) throws Error {
            app.connect_saved (id);
            return null;
        }

        public override void launch_search (string[] terms, uint32 timestamp) {
            app.activate ();
        }
    }
}
