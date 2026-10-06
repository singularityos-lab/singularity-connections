#include "rdp-bridge.h"

#include <string.h>

#include <freerdp/freerdp.h>
#include <freerdp/client.h>
#include <freerdp/gdi/gdi.h>
#include <freerdp/channels/channels.h>
#include <freerdp/client/channels.h>
#include <freerdp/event.h>
#include <freerdp/settings.h>
#include <freerdp/input.h>
#include <freerdp/client/cliprdr.h>
#include <winpr/user.h>
#include <winpr/synch.h>
#include <winpr/user.h>
#include <freerdp/client/cliprdr.h>
#include <freerdp/channels/cliprdr.h>

typedef struct {
  rdpClientContext common;
  SintyRdp *owner;
} SintyContext;

typedef struct {
  gint kind;
  guint16 flags;
  gint x;
  gint y;
  guint32 code;
  gboolean down;
} InputEvent;

struct _SintyRdp {
  rdpContext *context;
  GThread *thread;
  GRecMutex lock;
  GAsyncQueue *queue;
  HANDLE wake;
  volatile gint stop;
  gint width;
  gint height;
  gint dx1, dy1, dx2, dy2;
  gboolean dirty;
  gboolean frame_scheduled;
  gchar *trusted;
  gchar *pending;
  gchar *username;
  gchar *password;
  gchar *domain;
  SintyRdpReadyFunc ready_cb;
  SintyRdpFrameFunc frame_cb;
  SintyRdpClosedFunc closed_cb;
  SintyRdpClipboardFunc clipboard_cb;
  gpointer user_data;
  CliprdrClientContext *clip;
  gboolean clip_ready;
  gchar *local_text;
  gint ref;
};

typedef struct {
  SintyRdp *rdp;
  gint kind;
  gchar *message;
} Closed;

static SintyRdp *owner_of (rdpContext *context) {
  return ((SintyContext *) context)->owner;
}

static void rdp_ref (SintyRdp *rdp) {
  g_atomic_int_inc (&rdp->ref);
}

static void rdp_unref (SintyRdp *rdp) {
  if (!g_atomic_int_dec_and_test (&rdp->ref))
    return;
  if (rdp->context)
    freerdp_client_context_free (rdp->context);
  if (rdp->queue)
    g_async_queue_unref (rdp->queue);
  if (rdp->wake)
    CloseHandle (rdp->wake);
  g_rec_mutex_clear (&rdp->lock);
  g_free (rdp->trusted);
  g_free (rdp->pending);
  g_free (rdp->username);
  g_free (rdp->password);
  g_free (rdp->domain);
  g_free (rdp->local_text);
  g_free (rdp);
}

static gboolean emit_ready (gpointer data) {
  SintyRdp *rdp = data;
  if (!g_atomic_int_get (&rdp->stop) && rdp->ready_cb)
    rdp->ready_cb (rdp->user_data);
  rdp_unref (rdp);
  return G_SOURCE_REMOVE;
}

static gboolean emit_frame (gpointer data) {
  SintyRdp *rdp = data;
  g_rec_mutex_lock (&rdp->lock);
  rdp->frame_scheduled = FALSE;
  g_rec_mutex_unlock (&rdp->lock);
  if (!g_atomic_int_get (&rdp->stop) && rdp->frame_cb)
    rdp->frame_cb (rdp->user_data);
  rdp_unref (rdp);
  return G_SOURCE_REMOVE;
}

static gboolean emit_closed (gpointer data) {
  Closed *c = data;
  if (c->rdp->closed_cb)
    c->rdp->closed_cb (c->kind, c->message, c->rdp->user_data);
  rdp_unref (c->rdp);
  g_free (c->message);
  g_free (c);
  return G_SOURCE_REMOVE;
}

static void schedule_frame (SintyRdp *rdp) {
  if (rdp->frame_scheduled)
    return;
  rdp->frame_scheduled = TRUE;
  rdp_ref (rdp);
  g_idle_add_full (G_PRIORITY_HIGH_IDLE, emit_frame, rdp, NULL);
}

static BOOL on_begin_paint (rdpContext *context) {
  rdpGdi *gdi = context->gdi;
  g_rec_mutex_lock (&owner_of (context)->lock);
  gdi->primary->hdc->hwnd->invalid->null = TRUE;
  gdi->primary->hdc->hwnd->ninvalid = 0;
  return TRUE;
}

static BOOL on_end_paint (rdpContext *context) {
  SintyRdp *rdp = owner_of (context);
  rdpGdi *gdi = context->gdi;
  HGDI_RGN invalid = gdi->primary->hdc->hwnd->invalid;
  if (!invalid->null) {
    gint x1 = invalid->x, y1 = invalid->y;
    gint x2 = invalid->x + invalid->w, y2 = invalid->y + invalid->h;
    if (!rdp->dirty) {
      rdp->dx1 = x1; rdp->dy1 = y1; rdp->dx2 = x2; rdp->dy2 = y2;
    } else {
      rdp->dx1 = MIN (rdp->dx1, x1); rdp->dy1 = MIN (rdp->dy1, y1);
      rdp->dx2 = MAX (rdp->dx2, x2); rdp->dy2 = MAX (rdp->dy2, y2);
    }
    rdp->dirty = TRUE;
    schedule_frame (rdp);
  }
  g_rec_mutex_unlock (&rdp->lock);
  return TRUE;
}

static BOOL on_desktop_resize (rdpContext *context) {
  SintyRdp *rdp = owner_of (context);
  rdpSettings *settings = context->settings;
  gint w = freerdp_settings_get_uint32 (settings, FreeRDP_DesktopWidth);
  gint h = freerdp_settings_get_uint32 (settings, FreeRDP_DesktopHeight);
  g_rec_mutex_lock (&rdp->lock);
  BOOL ok = gdi_resize (context->gdi, w, h);
  rdp->width = w;
  rdp->height = h;
  rdp->dx1 = 0; rdp->dy1 = 0; rdp->dx2 = w; rdp->dy2 = h;
  rdp->dirty = TRUE;
  schedule_frame (rdp);
  g_rec_mutex_unlock (&rdp->lock);
  return ok;
}

typedef struct {
  SintyRdp *rdp;
  gchar *text;
} RemoteText;

static gboolean emit_clipboard (gpointer data) {
  RemoteText *t = data;
  if (!g_atomic_int_get (&t->rdp->stop) && t->rdp->clipboard_cb)
    t->rdp->clipboard_cb (t->text, t->rdp->user_data);
  rdp_unref (t->rdp);
  g_free (t->text);
  g_free (t);
  return G_SOURCE_REMOVE;
}

static UINT clip_announce (SintyRdp *rdp) {
  CliprdrClientContext *clip = rdp->clip;
  if (!clip || !rdp->clip_ready)
    return CHANNEL_RC_OK;
  g_rec_mutex_lock (&rdp->lock);
  gboolean has_text = rdp->local_text != NULL;
  g_rec_mutex_unlock (&rdp->lock);
  CLIPRDR_FORMAT format = { .formatId = CF_UNICODETEXT, .formatName = NULL };
  CLIPRDR_FORMAT_LIST list = { 0 };
  list.common.msgType = CB_FORMAT_LIST;
  list.numFormats = has_text ? 1 : 0;
  list.formats = has_text ? &format : NULL;
  return clip->ClientFormatList (clip, &list);
}

static UINT clip_monitor_ready (CliprdrClientContext *clip, const CLIPRDR_MONITOR_READY *ready) {
  SintyRdp *rdp = clip->custom;
  CLIPRDR_GENERAL_CAPABILITY_SET general = { 0 };
  general.capabilitySetType = CB_CAPSTYPE_GENERAL;
  general.capabilitySetLength = CB_CAPSTYPE_GENERAL_LEN;
  general.version = CB_CAPS_VERSION_2;
  general.generalFlags = CB_USE_LONG_FORMAT_NAMES;
  CLIPRDR_CAPABILITIES caps = { 0 };
  caps.cCapabilitiesSets = 1;
  caps.capabilitySets = (CLIPRDR_CAPABILITY_SET *) &general;
  UINT rc = clip->ClientCapabilities (clip, &caps);
  if (rc != CHANNEL_RC_OK)
    return rc;
  rdp->clip_ready = TRUE;
  return clip_announce (rdp);
}

static UINT clip_server_capabilities (CliprdrClientContext *clip, const CLIPRDR_CAPABILITIES *caps) {
  return CHANNEL_RC_OK;
}

static UINT clip_server_format_list (CliprdrClientContext *clip, const CLIPRDR_FORMAT_LIST *list) {
  CLIPRDR_FORMAT_LIST_RESPONSE response = { 0 };
  response.common.msgType = CB_FORMAT_LIST_RESPONSE;
  response.common.msgFlags = CB_RESPONSE_OK;
  UINT rc = clip->ClientFormatListResponse (clip, &response);
  if (rc != CHANNEL_RC_OK)
    return rc;
  for (UINT32 i = 0; i < list->numFormats; i++) {
    if (list->formats[i].formatId == CF_UNICODETEXT) {
      CLIPRDR_FORMAT_DATA_REQUEST request = { 0 };
      request.common.msgType = CB_FORMAT_DATA_REQUEST;
      request.requestedFormatId = CF_UNICODETEXT;
      return clip->ClientFormatDataRequest (clip, &request);
    }
  }
  return CHANNEL_RC_OK;
}

static UINT clip_server_format_list_response (CliprdrClientContext *clip, const CLIPRDR_FORMAT_LIST_RESPONSE *response) {
  return CHANNEL_RC_OK;
}

static UINT clip_server_data_response (CliprdrClientContext *clip, const CLIPRDR_FORMAT_DATA_RESPONSE *response) {
  SintyRdp *rdp = clip->custom;
  if (!(response->common.msgFlags & CB_RESPONSE_OK) || !response->requestedFormatData || response->common.dataLen < 2)
    return CHANNEL_RC_OK;
  glong units = response->common.dataLen / 2;
  const gunichar2 *utf16 = (const gunichar2 *) response->requestedFormatData;
  while (units > 0 && utf16[units - 1] == 0)
    units--;
  gchar *text = g_utf16_to_utf8 (utf16, units, NULL, NULL, NULL);
  if (!text)
    return CHANNEL_RC_OK;
  g_rec_mutex_lock (&rdp->lock);
  g_free (rdp->local_text);
  rdp->local_text = g_strdup (text);
  g_rec_mutex_unlock (&rdp->lock);
  RemoteText *t = g_new0 (RemoteText, 1);
  t->rdp = rdp;
  t->text = text;
  rdp_ref (rdp);
  g_idle_add (emit_clipboard, t);
  return CHANNEL_RC_OK;
}

static UINT clip_server_data_request (CliprdrClientContext *clip, const CLIPRDR_FORMAT_DATA_REQUEST *request) {
  SintyRdp *rdp = clip->custom;
  CLIPRDR_FORMAT_DATA_RESPONSE response = { 0 };
  response.common.msgType = CB_FORMAT_DATA_RESPONSE;
  gunichar2 *utf16 = NULL;
  glong written = 0;
  g_rec_mutex_lock (&rdp->lock);
  if (request->requestedFormatId == CF_UNICODETEXT && rdp->local_text) {
    gchar **parts = g_strsplit (rdp->local_text, "\n", -1);
    gchar *crlf = g_strjoinv ("\r\n", parts);
    g_strfreev (parts);
    utf16 = g_utf8_to_utf16 (crlf, -1, NULL, &written, NULL);
    g_free (crlf);
  }
  g_rec_mutex_unlock (&rdp->lock);
  if (utf16) {
    response.common.msgFlags = CB_RESPONSE_OK;
    response.common.dataLen = (UINT32) ((written + 1) * 2);
    response.requestedFormatData = (const BYTE *) utf16;
  } else {
    response.common.msgFlags = CB_RESPONSE_FAIL;
  }
  UINT rc = clip->ClientFormatDataResponse (clip, &response);
  g_free (utf16);
  return rc;
}

static void on_channel_connected (void *context, const ChannelConnectedEventArgs *e) {
  SintyRdp *rdp = owner_of (context);
  if (strcmp (e->name, CLIPRDR_SVC_CHANNEL_NAME) == 0) {
    CliprdrClientContext *clip = e->pInterface;
    clip->custom = rdp;
    clip->MonitorReady = clip_monitor_ready;
    clip->ServerCapabilities = clip_server_capabilities;
    clip->ServerFormatList = clip_server_format_list;
    clip->ServerFormatListResponse = clip_server_format_list_response;
    clip->ServerFormatDataResponse = clip_server_data_response;
    clip->ServerFormatDataRequest = clip_server_data_request;
    rdp->clip = clip;
    return;
  }
  freerdp_client_OnChannelConnectedEventHandler (context, e);
}

static void on_channel_disconnected (void *context, const ChannelDisconnectedEventArgs *e) {
  SintyRdp *rdp = owner_of (context);
  if (strcmp (e->name, CLIPRDR_SVC_CHANNEL_NAME) == 0) {
    CliprdrClientContext *clip = e->pInterface;
    clip->custom = NULL;
    rdp->clip = NULL;
    rdp->clip_ready = FALSE;
    return;
  }
  freerdp_client_OnChannelDisconnectedEventHandler (context, e);
}


static BOOL on_pre_connect (freerdp *instance) {
  rdpSettings *settings = instance->context->settings;
  freerdp_settings_set_uint32 (settings, FreeRDP_OsMajorType, OSMAJORTYPE_UNIX);
  freerdp_settings_set_uint32 (settings, FreeRDP_OsMinorType, OSMINORTYPE_NATIVE_WAYLAND);
  PubSub_SubscribeChannelConnected (instance->context->pubSub, on_channel_connected);
  PubSub_SubscribeChannelDisconnected (instance->context->pubSub, on_channel_disconnected);
  return TRUE;
}

static BOOL on_post_connect (freerdp *instance) {
  SintyRdp *rdp = owner_of (instance->context);
  if (!gdi_init (instance, PIXEL_FORMAT_BGRX32))
    return FALSE;
  instance->context->update->BeginPaint = on_begin_paint;
  instance->context->update->EndPaint = on_end_paint;
  instance->context->update->DesktopResize = on_desktop_resize;
  g_rec_mutex_lock (&rdp->lock);
  rdp->width = instance->context->gdi->width;
  rdp->height = instance->context->gdi->height;
  g_rec_mutex_unlock (&rdp->lock);
  return TRUE;
}

static void on_post_disconnect (freerdp *instance) {
  if (!instance || !instance->context)
    return;
  PubSub_UnsubscribeChannelConnected (instance->context->pubSub, on_channel_connected);
  PubSub_UnsubscribeChannelDisconnected (instance->context->pubSub, on_channel_disconnected);
  gdi_free (instance);
}

static BOOL on_authenticate (freerdp *instance, char **username, char **password, char **domain, rdp_auth_reason reason) {
  SintyRdp *rdp = owner_of (instance->context);
  if (!rdp->password || !*rdp->password)
    return FALSE;
  if (!*username && rdp->username) {
    free (*username);
    *username = strdup (rdp->username);
  }
  if ((!*password || !**password) && rdp->password) {
    free (*password);
    *password = strdup (rdp->password);
  }
  if ((!*domain || !**domain) && rdp->domain && *rdp->domain) {
    free (*domain);
    *domain = strdup (rdp->domain);
  }
  return TRUE;
}

static DWORD check_fingerprint (SintyRdp *rdp, const char *fingerprint) {
  if (fingerprint && rdp->trusted && g_ascii_strcasecmp (fingerprint, rdp->trusted) == 0)
    return 2;
  g_rec_mutex_lock (&rdp->lock);
  g_free (rdp->pending);
  rdp->pending = g_strdup (fingerprint ? fingerprint : "");
  g_rec_mutex_unlock (&rdp->lock);
  return 0;
}

static DWORD on_verify_certificate (freerdp *instance, const char *host, UINT16 port, const char *common_name,
                                    const char *subject, const char *issuer, const char *fingerprint, DWORD flags) {
  return check_fingerprint (owner_of (instance->context), fingerprint);
}

static DWORD on_verify_changed (freerdp *instance, const char *host, UINT16 port, const char *common_name,
                                const char *subject, const char *issuer, const char *new_fingerprint,
                                const char *old_subject, const char *old_issuer, const char *old_fingerprint,
                                DWORD flags) {
  return check_fingerprint (owner_of (instance->context), new_fingerprint);
}

static BOOL on_client_new (freerdp *instance, rdpContext *context) {
  instance->PreConnect = on_pre_connect;
  instance->PostConnect = on_post_connect;
  instance->PostDisconnect = on_post_disconnect;
  instance->AuthenticateEx = on_authenticate;
  instance->VerifyCertificateEx = on_verify_certificate;
  instance->VerifyChangedCertificateEx = on_verify_changed;
  return TRUE;
}

static int entry_points (RDP_CLIENT_ENTRY_POINTS *ep) {
  memset (ep, 0, sizeof (RDP_CLIENT_ENTRY_POINTS));
  ep->Version = RDP_CLIENT_INTERFACE_VERSION;
  ep->Size = sizeof (RDP_CLIENT_ENTRY_POINTS_V1);
  ep->ContextSize = sizeof (SintyContext);
  ep->ClientNew = on_client_new;
  return 0;
}

SintyRdp *sinty_rdp_new (const gchar *host, gint port, const gchar *username, const gchar *password,
                         const gchar *domain, const gchar *trusted_fingerprint, gint width, gint height,
                         SintyRdpReadyFunc ready, SintyRdpFrameFunc frame, SintyRdpClosedFunc closed,
                         gpointer user_data) {
  RDP_CLIENT_ENTRY_POINTS ep;
  entry_points (&ep);
  rdpContext *context = freerdp_client_context_new (&ep);
  if (!context)
    return NULL;
  SintyRdp *rdp = g_new0 (SintyRdp, 1);
  rdp->ref = 1;
  rdp->context = context;
  ((SintyContext *) context)->owner = rdp;
  g_rec_mutex_init (&rdp->lock);
  rdp->queue = g_async_queue_new_full (g_free);
  rdp->wake = CreateEventA (NULL, TRUE, FALSE, NULL);
  rdp->trusted = g_strdup (trusted_fingerprint);
  rdp->username = g_strdup (username);
  rdp->password = g_strdup (password);
  rdp->domain = g_strdup (domain);
  rdp->ready_cb = ready;
  rdp->frame_cb = frame;
  rdp->closed_cb = closed;
  rdp->user_data = user_data;

  rdpSettings *s = context->settings;
  freerdp_settings_set_string (s, FreeRDP_ServerHostname, host);
  freerdp_settings_set_uint32 (s, FreeRDP_ServerPort, port > 0 ? port : 3389);
  if (username && *username)
    freerdp_settings_set_string (s, FreeRDP_Username, username);
  if (password && *password) {
    freerdp_settings_set_string (s, FreeRDP_Password, password);
    freerdp_settings_set_bool (s, FreeRDP_AutoLogonEnabled, TRUE);
  }
  if (domain && *domain)
    freerdp_settings_set_string (s, FreeRDP_Domain, domain);
  freerdp_settings_set_uint32 (s, FreeRDP_DesktopWidth, CLAMP (width, 640, 8192) & ~1);
  freerdp_settings_set_uint32 (s, FreeRDP_DesktopHeight, CLAMP (height, 480, 8192));
  freerdp_settings_set_uint32 (s, FreeRDP_ColorDepth, 32);
  freerdp_settings_set_bool (s, FreeRDP_SoftwareGdi, TRUE);
  freerdp_settings_set_bool (s, FreeRDP_SupportGraphicsPipeline, TRUE);
  freerdp_settings_set_bool (s, FreeRDP_GfxH264, FALSE);
  freerdp_settings_set_bool (s, FreeRDP_GfxAVC444, FALSE);
  freerdp_settings_set_bool (s, FreeRDP_RemoteFxCodec, TRUE);
  freerdp_settings_set_bool (s, FreeRDP_SupportDisplayControl, TRUE);
  freerdp_settings_set_bool (s, FreeRDP_DynamicResolutionUpdate, TRUE);
  freerdp_settings_set_bool (s, FreeRDP_NetworkAutoDetect, TRUE);
  freerdp_settings_set_uint32 (s, FreeRDP_ConnectionType, CONNECTION_TYPE_AUTODETECT);
  freerdp_settings_set_bool (s, FreeRDP_AllowFontSmoothing, TRUE);
  freerdp_settings_set_bool (s, FreeRDP_AllowDesktopComposition, TRUE);
  freerdp_settings_set_bool (s, FreeRDP_AutoReconnectionEnabled, TRUE);
  freerdp_settings_set_bool (s, FreeRDP_RedirectClipboard, TRUE);
  freerdp_settings_set_uint32 (s, FreeRDP_KeyboardLayout, 0);
  return rdp;
}

static void post_closed (SintyRdp *rdp, gint kind, const gchar *message) {
  Closed *c = g_new0 (Closed, 1);
  c->rdp = rdp;
  c->kind = kind;
  c->message = g_strdup (message);
  rdp_ref (rdp);
  g_idle_add (emit_closed, c);
}

static void drain_input (SintyRdp *rdp) {
  rdpInput *input = rdp->context->input;
  InputEvent *e;
  while ((e = g_async_queue_try_pop (rdp->queue)) != NULL) {
    if (e->kind == 0)
      freerdp_input_send_mouse_event (input, e->flags, e->x, e->y);
    else if (e->kind == 1)
      freerdp_input_send_keyboard_event_ex (input, e->down, FALSE, e->code);
    else if (e->kind == 2)
      freerdp_input_send_unicode_keyboard_event (input, e->down ? 0 : KBD_FLAGS_RELEASE, (UINT16) e->code);
    else
      clip_announce (rdp);
    g_free (e);
  }
}

static gpointer thread_main (gpointer data) {
  SintyRdp *rdp = data;
  freerdp *instance = rdp->context->instance;
  if (!freerdp_connect (instance)) {
    UINT32 code = freerdp_get_last_error (rdp->context);
    gint kind = SINTY_RDP_CLOSED_ERROR;
    g_rec_mutex_lock (&rdp->lock);
    gboolean untrusted = rdp->pending && *rdp->pending;
    g_rec_mutex_unlock (&rdp->lock);
    if (untrusted)
      kind = SINTY_RDP_CLOSED_UNTRUSTED;
    else if (code == FREERDP_ERROR_AUTHENTICATION_FAILED || code == FREERDP_ERROR_CONNECT_LOGON_FAILURE ||
             code == FREERDP_ERROR_CONNECT_WRONG_PASSWORD || code == FREERDP_ERROR_CONNECT_NO_OR_MISSING_CREDENTIALS ||
             code == FREERDP_ERROR_CONNECT_CANCELLED)
      kind = SINTY_RDP_CLOSED_AUTH;
    if (g_atomic_int_get (&rdp->stop))
      kind = SINTY_RDP_CLOSED_OK;
    post_closed (rdp, kind, freerdp_get_last_error_string (code));
    rdp_unref (rdp);
    return NULL;
  }
  rdp_ref (rdp);
  g_idle_add (emit_ready, rdp);
  HANDLE handles[MAXIMUM_WAIT_OBJECTS];
  const gchar *failure = NULL;
  while (!g_atomic_int_get (&rdp->stop) && !freerdp_shall_disconnect_context (rdp->context)) {
    DWORD n = freerdp_get_event_handles (rdp->context, handles, ARRAYSIZE (handles) - 1);
    if (n == 0) {
      failure = "event handles";
      break;
    }
    handles[n++] = rdp->wake;
    DWORD status = WaitForMultipleObjects (n, handles, FALSE, 100);
    if (status == WAIT_FAILED) {
      failure = "wait";
      break;
    }
    ResetEvent (rdp->wake);
    drain_input (rdp);
    if (!freerdp_check_event_handles (rdp->context)) {
      if (freerdp_get_last_error (rdp->context) != FREERDP_ERROR_SUCCESS)
        failure = freerdp_get_last_error_string (freerdp_get_last_error (rdp->context));
      break;
    }
  }
  gboolean stopped = g_atomic_int_get (&rdp->stop);
  freerdp_disconnect (instance);
  post_closed (rdp, stopped || !failure ? SINTY_RDP_CLOSED_OK : SINTY_RDP_CLOSED_ERROR, failure);
  rdp_unref (rdp);
  return NULL;
}

gboolean sinty_rdp_start (SintyRdp *rdp) {
  rdp_ref (rdp);
  rdp->thread = g_thread_new ("rdp", thread_main, rdp);
  return rdp->thread != NULL;
}

void sinty_rdp_stop (SintyRdp *rdp) {
  if (g_atomic_int_get (&rdp->stop))
    return;
  g_atomic_int_set (&rdp->stop, 1);
  freerdp_abort_connect_context (rdp->context);
  SetEvent (rdp->wake);
}

void sinty_rdp_free (SintyRdp *rdp) {
  sinty_rdp_stop (rdp);
  rdp->ready_cb = NULL;
  rdp->frame_cb = NULL;
  rdp->closed_cb = NULL;
  rdp->clipboard_cb = NULL;
  if (rdp->thread) {
    g_thread_unref (rdp->thread);
    rdp->thread = NULL;
  }
  rdp_unref (rdp);
}

gint sinty_rdp_get_width (SintyRdp *rdp) {
  g_rec_mutex_lock (&rdp->lock);
  gint w = rdp->width;
  g_rec_mutex_unlock (&rdp->lock);
  return w;
}

gint sinty_rdp_get_height (SintyRdp *rdp) {
  g_rec_mutex_lock (&rdp->lock);
  gint h = rdp->height;
  g_rec_mutex_unlock (&rdp->lock);
  return h;
}

gchar *sinty_rdp_get_pending_fingerprint (SintyRdp *rdp) {
  g_rec_mutex_lock (&rdp->lock);
  gchar *fp = g_strdup (rdp->pending ? rdp->pending : "");
  g_rec_mutex_unlock (&rdp->lock);
  return fp;
}

gboolean sinty_rdp_blit (SintyRdp *rdp, guint8 *dest, gint dest_len, gint dest_width, gint dest_height,
                         gint *x, gint *y, gint *w, gint *h) {
  gboolean copied = FALSE;
  g_rec_mutex_lock (&rdp->lock);
  rdpGdi *gdi = rdp->context->gdi;
  if (rdp->dirty && gdi && gdi->primary_buffer && gdi->width == dest_width && gdi->height == dest_height &&
      dest_len >= dest_width * dest_height * 4) {
    gint x1 = CLAMP (rdp->dx1, 0, dest_width), y1 = CLAMP (rdp->dy1, 0, dest_height);
    gint x2 = CLAMP (rdp->dx2, 0, dest_width), y2 = CLAMP (rdp->dy2, 0, dest_height);
    for (gint row = y1; row < y2; row++)
      memcpy (dest + (gsize) row * dest_width * 4 + x1 * 4, gdi->primary_buffer + (gsize) row * gdi->stride + x1 * 4,
              (gsize) (x2 - x1) * 4);
    *x = x1; *y = y1; *w = x2 - x1; *h = y2 - y1;
    rdp->dirty = FALSE;
    copied = x2 > x1 && y2 > y1;
  }
  g_rec_mutex_unlock (&rdp->lock);
  return copied;
}

static void push (SintyRdp *rdp, InputEvent *e) {
  if (g_atomic_int_get (&rdp->stop)) {
    g_free (e);
    return;
  }
  g_async_queue_push (rdp->queue, e);
  SetEvent (rdp->wake);
}

void sinty_rdp_send_mouse (SintyRdp *rdp, guint16 flags, gint x, gint y) {
  InputEvent *e = g_new0 (InputEvent, 1);
  e->kind = 0;
  e->flags = flags;
  e->x = x;
  e->y = y;
  push (rdp, e);
}

void sinty_rdp_send_key (SintyRdp *rdp, gboolean down, guint32 scancode) {
  InputEvent *e = g_new0 (InputEvent, 1);
  e->kind = 1;
  e->down = down;
  e->code = scancode;
  push (rdp, e);
}

void sinty_rdp_send_unicode (SintyRdp *rdp, gboolean down, guint16 code) {
  InputEvent *e = g_new0 (InputEvent, 1);
  e->kind = 2;
  e->down = down;
  e->code = code;
  push (rdp, e);
}

void sinty_rdp_set_clipboard_callback (SintyRdp *rdp, SintyRdpClipboardFunc func) {
  rdp->clipboard_cb = func;
}

void sinty_rdp_set_clipboard (SintyRdp *rdp, const gchar *text) {
  g_rec_mutex_lock (&rdp->lock);
  gboolean same = g_strcmp0 (rdp->local_text, text) == 0;
  if (!same) {
    g_free (rdp->local_text);
    rdp->local_text = g_strdup (text);
  }
  g_rec_mutex_unlock (&rdp->lock);
  if (same)
    return;
  InputEvent *e = g_new0 (InputEvent, 1);
  e->kind = 3;
  push (rdp, e);
}

