using Singularity.Remote;

namespace Singularity.Apps.Connections {

    public class RdpSession : RemoteSession {
        public RdpSession (string host, int port, int width, int height) {
            Object (host: host, port: port);
        }

        public override void start () {
            Idle.add (() => {
                closed (new SessionError.UNSUPPORTED (_("This copy of Connections was built without Remote Desktop support.")));
                return Source.REMOVE;
            });
        }

        public override void stop () {
        }

        public override void provide_credentials (string username, string password, string domain) {
        }

        public override void send_pointer (int x, int y, uint buttons) {
        }

        public override void send_scroll (int x, int y, double dx, double dy) {
        }

        public override void send_key (uint keyval, uint keycode, bool pressed) {
        }

        public override void send_clipboard (string text) {
        }
    }
}
