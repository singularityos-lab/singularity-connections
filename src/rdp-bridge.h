#pragma once

#include <glib.h>

G_BEGIN_DECLS

typedef struct _SintyRdp SintyRdp;

typedef void (*SintyRdpReadyFunc) (gpointer user_data);
typedef void (*SintyRdpFrameFunc) (gpointer user_data);
typedef void (*SintyRdpClosedFunc) (gint kind, const gchar *message, gpointer user_data);
typedef void (*SintyRdpClipboardFunc) (const gchar *text, gpointer user_data);

enum {
  SINTY_RDP_CLOSED_OK = 0,
  SINTY_RDP_CLOSED_ERROR = 1,
  SINTY_RDP_CLOSED_AUTH = 2,
  SINTY_RDP_CLOSED_UNTRUSTED = 3
};

SintyRdp *sinty_rdp_new (const gchar *host, gint port, const gchar *username, const gchar *password,
                         const gchar *domain, const gchar *trusted_fingerprint, gint width, gint height,
                         SintyRdpReadyFunc ready, SintyRdpFrameFunc frame, SintyRdpClosedFunc closed,
                         gpointer user_data);
gboolean sinty_rdp_start (SintyRdp *rdp);
void sinty_rdp_stop (SintyRdp *rdp);
void sinty_rdp_free (SintyRdp *rdp);
gint sinty_rdp_get_width (SintyRdp *rdp);
gint sinty_rdp_get_height (SintyRdp *rdp);
gchar *sinty_rdp_get_pending_fingerprint (SintyRdp *rdp);
gboolean sinty_rdp_blit (SintyRdp *rdp, guint8 *dest, gint dest_len, gint dest_width, gint dest_height,
                         gint *x, gint *y, gint *w, gint *h);
void sinty_rdp_send_mouse (SintyRdp *rdp, guint16 flags, gint x, gint y);
void sinty_rdp_send_key (SintyRdp *rdp, gboolean down, guint32 scancode);
void sinty_rdp_send_unicode (SintyRdp *rdp, gboolean down, guint16 code);
void sinty_rdp_set_clipboard_callback (SintyRdp *rdp, SintyRdpClipboardFunc func);
void sinty_rdp_set_clipboard (SintyRdp *rdp, const gchar *text);

G_END_DECLS
