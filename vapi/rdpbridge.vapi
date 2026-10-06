[CCode (cheader_filename = "rdp-bridge.h")]
namespace RdpBridge {
    [CCode (cname = "SintyRdpReadyFunc", has_target = false)]
    public delegate void ReadyFunc (void* user_data);
    [CCode (cname = "SintyRdpFrameFunc", has_target = false)]
    public delegate void FrameFunc (void* user_data);
    [CCode (cname = "SintyRdpClosedFunc", has_target = false)]
    public delegate void ClosedFunc (int kind, string? message, void* user_data);

    [CCode (cname = "SintyRdpClipboardFunc", has_target = false)]
    public delegate void ClipboardFunc (string text, void* user_data);

    [CCode (cname = "SINTY_RDP_CLOSED_OK")]
    public const int CLOSED_OK;
    [CCode (cname = "SINTY_RDP_CLOSED_ERROR")]
    public const int CLOSED_ERROR;
    [CCode (cname = "SINTY_RDP_CLOSED_AUTH")]
    public const int CLOSED_AUTH;
    [CCode (cname = "SINTY_RDP_CLOSED_UNTRUSTED")]
    public const int CLOSED_UNTRUSTED;

    [Compact]
    [CCode (cname = "SintyRdp", free_function = "sinty_rdp_free")]
    public class Client {
        [CCode (cname = "sinty_rdp_new")]
        public static Client? create (string host, int port, string username, string password, string domain, string trusted, int width, int height, ReadyFunc ready, FrameFunc frame, ClosedFunc closed, void* user_data);
        [CCode (cname = "sinty_rdp_start")]
        public bool start ();
        [CCode (cname = "sinty_rdp_stop")]
        public void stop ();
        [CCode (cname = "sinty_rdp_get_width")]
        public int get_width ();
        [CCode (cname = "sinty_rdp_get_height")]
        public int get_height ();
        [CCode (cname = "sinty_rdp_get_pending_fingerprint")]
        public string get_pending_fingerprint ();
        [CCode (cname = "sinty_rdp_blit")]
        public bool blit ([CCode (array_length_type = "gint")] uint8[] dest, int dest_width, int dest_height, out int x, out int y, out int w, out int h);
        [CCode (cname = "sinty_rdp_send_mouse")]
        public void send_mouse (uint16 flags, int x, int y);
        [CCode (cname = "sinty_rdp_send_key")]
        public void send_key (bool down, uint32 scancode);
        [CCode (cname = "sinty_rdp_send_unicode")]
        public void send_unicode (bool down, uint16 code);
        [CCode (cname = "sinty_rdp_set_clipboard_callback")]
        public void set_clipboard_callback (ClipboardFunc func);
        [CCode (cname = "sinty_rdp_set_clipboard")]
        public void set_clipboard (string text);
    }
}
