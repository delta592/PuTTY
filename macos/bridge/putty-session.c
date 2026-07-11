/*
 * putty-session.c — PuttySession lifecycle (Phase 3.2).
 */

#include <assert.h>
#include <string.h>

#include "putty-bridge-internal.h"

#include "putty-bridge-thread.h"

static const TermWinVtable bridge_termwin_vt;
static const SeatVtable bridge_seat_vt;
static const LogPolicyVtable bridge_logpolicy_vt;

static PuttySession *session_from_seat(Seat *seat)
{
    return container_of(seat, PuttySession, seat);
}

static PuttySession *session_from_termwin(TermWin *tw)
{
    return container_of(tw, PuttySession, termwin);
}

static Conf *session_new_conf(const PuttyConf *conf)
{
    PuttyConf *defaults;
    Conf *copy;

    copy = putty_bridge_conf_copy(conf);
    if (copy)
        return copy;

    defaults = putty_conf_new();
    copy = defaults->conf;
    defaults->conf = NULL;
    putty_conf_free(defaults);
    return copy;
}

static void session_destroy_connection(PuttySession *session)
{
    session->exited = true;
    if (session->ldisc) {
        ldisc_free(session->ldisc);
        session->ldisc = NULL;
    }
    if (session->backend) {
        backend_free(session->backend);
        session->backend = NULL;
    }
    if (session->term)
        term_provide_backend(session->term, NULL);
    session->started = false;
}

static void session_exit_callback(void *vctx)
{
    PuttySession *session = (PuttySession *)vctx;

    if (session->callbacks.on_exit)
        session->callbacks.on_exit(session->callback_ctx);
}

static void session_queue_exit(PuttySession *session)
{
    queue_toplevel_callback(session_exit_callback, session);
}

/* --- TermWin (minimal stub; full draw path in Phase 4) --- */

static bool bridge_termwin_setup_draw_ctx(TermWin *tw)
{
    (void)tw;
    return true;
}

static void bridge_termwin_draw_text(
    TermWin *tw, int x, int y, wchar_t *text, int len,
    unsigned long attr, int lattr, truecolour tc)
{
    (void)tw; (void)x; (void)y; (void)text; (void)len;
    (void)attr; (void)lattr; (void)tc;
}

static void bridge_termwin_draw_cursor(
    TermWin *tw, int x, int y, wchar_t *text, int len,
    unsigned long attr, int lattr, truecolour tc)
{
    (void)tw; (void)x; (void)y; (void)text; (void)len;
    (void)attr; (void)lattr; (void)tc;
}

static void bridge_termwin_draw_trust_sigil(TermWin *tw, int x, int y)
{
    (void)tw; (void)x; (void)y;
}

static int bridge_termwin_char_width(TermWin *tw, int uc)
{
    (void)tw;
    (void)uc;
    return 1;
}

static void bridge_termwin_free_draw_ctx(TermWin *tw)
{
    (void)tw;
}

static void bridge_termwin_set_cursor_pos(TermWin *tw, int x, int y)
{
    (void)tw; (void)x; (void)y;
}

static void bridge_termwin_set_raw_mouse_mode(TermWin *tw, bool enable)
{
    (void)tw; (void)enable;
}

static void bridge_termwin_set_raw_mouse_mode_pointer(TermWin *tw, bool enable)
{
    (void)tw; (void)enable;
}

static void bridge_termwin_set_scrollbar(TermWin *tw, int total, int start, int page)
{
    (void)tw; (void)total; (void)start; (void)page;
}

static void bridge_termwin_bell(TermWin *tw, int mode)
{
    PuttySession *session = session_from_termwin(tw);
    if (session->callbacks.on_bell)
        session->callbacks.on_bell(session->callback_ctx, mode);
}

static void bridge_termwin_clip_write(
    TermWin *tw, int clipboard, wchar_t *text, int *attrs,
    truecolour *colours, int len, bool must_deselect)
{
    (void)tw; (void)clipboard; (void)text; (void)attrs;
    (void)colours; (void)len; (void)must_deselect;
}

static void bridge_termwin_clip_request_paste(TermWin *tw, int clipboard)
{
    (void)tw; (void)clipboard;
}

static void bridge_termwin_refresh(TermWin *tw)
{
    PuttySession *session = session_from_termwin(tw);
    PuttyBridgeRect dirty = {0, 0, 0, 0};

    if (session->term)
        term_invalidate(session->term);
    if (session->callbacks.on_request_redraw)
        session->callbacks.on_request_redraw(session->callback_ctx, dirty);
}

static void bridge_termwin_request_resize(TermWin *tw, int w, int h)
{
    (void)tw; (void)w; (void)h;
}

static void bridge_termwin_set_title(TermWin *tw, const char *title, int codepage)
{
    PuttySession *session = session_from_termwin(tw);
    (void)codepage;
    if (session->callbacks.on_title_changed)
        session->callbacks.on_title_changed(session->callback_ctx, title);
}

static void bridge_termwin_set_icon_title(TermWin *tw, const char *icontitle, int cp)
{
    PuttySession *session = session_from_termwin(tw);
    (void)cp;
    if (session->callbacks.on_title_changed)
        session->callbacks.on_title_changed(session->callback_ctx, icontitle);
}

static void bridge_termwin_set_minimised(TermWin *tw, bool minimised)
{
    (void)tw; (void)minimised;
}

static void bridge_termwin_set_maximised(TermWin *tw, bool maximised)
{
    (void)tw; (void)maximised;
}

static void bridge_termwin_move(TermWin *tw, int x, int y)
{
    (void)tw; (void)x; (void)y;
}

static void bridge_termwin_set_zorder(TermWin *tw, bool top)
{
    (void)tw; (void)top;
}

static void bridge_termwin_palette_set(
    TermWin *tw, unsigned start, unsigned ncolours, const rgb *colours)
{
    (void)tw; (void)start; (void)ncolours; (void)colours;
}

static void bridge_termwin_palette_get_overrides(TermWin *tw, Terminal *term)
{
    (void)tw; (void)term;
}

static void bridge_termwin_unthrottle(TermWin *tw, size_t bufsize)
{
    PuttySession *session = session_from_termwin(tw);
    if (session->backend)
        backend_unthrottle(session->backend, bufsize);
}

static const TermWinVtable bridge_termwin_vt = {
    .setup_draw_ctx = bridge_termwin_setup_draw_ctx,
    .draw_text = bridge_termwin_draw_text,
    .draw_cursor = bridge_termwin_draw_cursor,
    .draw_trust_sigil = bridge_termwin_draw_trust_sigil,
    .char_width = bridge_termwin_char_width,
    .free_draw_ctx = bridge_termwin_free_draw_ctx,
    .set_cursor_pos = bridge_termwin_set_cursor_pos,
    .set_raw_mouse_mode = bridge_termwin_set_raw_mouse_mode,
    .set_raw_mouse_mode_pointer = bridge_termwin_set_raw_mouse_mode_pointer,
    .set_scrollbar = bridge_termwin_set_scrollbar,
    .bell = bridge_termwin_bell,
    .clip_write = bridge_termwin_clip_write,
    .clip_request_paste = bridge_termwin_clip_request_paste,
    .refresh = bridge_termwin_refresh,
    .request_resize = bridge_termwin_request_resize,
    .set_title = bridge_termwin_set_title,
    .set_icon_title = bridge_termwin_set_icon_title,
    .set_minimised = bridge_termwin_set_minimised,
    .set_maximised = bridge_termwin_set_maximised,
    .move = bridge_termwin_move,
    .set_zorder = bridge_termwin_set_zorder,
    .palette_set = bridge_termwin_palette_set,
    .palette_get_overrides = bridge_termwin_palette_get_overrides,
    .unthrottle = bridge_termwin_unthrottle,
};

/* --- Seat --- */

static size_t bridge_seat_output(
    Seat *seat, SeatOutputType type, const void *data, size_t len)
{
    PuttySession *session = session_from_seat(seat);
    (void)type;
    if (session->callbacks.on_output && data && len > 0)
        session->callbacks.on_output(session->callback_ctx, data, len);
    if (!session->term)
        return 0;
    return term_data(session->term, data, len);
}

static bool bridge_seat_eof(Seat *seat)
{
    (void)seat;
    return true;
}

static SeatPromptResult bridge_seat_get_userpass_input(Seat *seat, prompts_t *p)
{
    PuttySession *session = session_from_seat(seat);
    SeatPromptResult spr;

    spr = cmdline_get_passwd_input(p, &session->cmdline_get_passwd_state, true);
    if (spr.kind == SPRK_INCOMPLETE && session->term)
        spr = term_get_userpass_input(session->term, p);
    return spr;
}

static void bridge_seat_notify_remote_exit(Seat *seat)
{
    PuttySession *session = session_from_seat(seat);
    int exitcode;

    if (!session->exited &&
        session->backend &&
        (exitcode = backend_exitcode(session->backend)) >= 0) {
        session_destroy_connection(session);
        session_queue_exit(session);
    }
}

static void bridge_seat_connection_fatal(Seat *seat, const char *msg)
{
    PuttySession *session = session_from_seat(seat);

    seat_stderr_pl(seat, ptrlen_from_asciz(msg));
    seat_stderr_pl(seat, PTRLEN_LITERAL("\r\n"));
    session->exited = true;
    session_destroy_connection(session);
    session_queue_exit(session);
}

static void bridge_seat_nonfatal(Seat *seat, const char *msg)
{
    seat_stderr_pl(seat, ptrlen_from_asciz(msg));
    seat_stderr_pl(seat, PTRLEN_LITERAL("\r\n"));
}

static char *bridge_seat_get_ttymode(Seat *seat, const char *mode)
{
    PuttySession *session = session_from_seat(seat);
    if (!session->term)
        return NULL;
    return term_get_ttymode(session->term, mode);
}

static void bridge_seat_set_trust_status(Seat *seat, bool trusted)
{
    PuttySession *session = session_from_seat(seat);
    if (session->term)
        term_set_trust_status(session->term, trusted);
}

static bool bridge_seat_can_set_trust_status(Seat *seat)
{
    (void)seat;
    return true;
}

static bool bridge_seat_is_utf8(Seat *seat)
{
    PuttySession *session = session_from_seat(seat);
    return session->ucsdata.line_codepage == CS_UTF8;
}

static bool bridge_seat_get_cursor_position(Seat *seat, int *x, int *y)
{
    PuttySession *session = session_from_seat(seat);
    if (!session->term)
        return false;
    term_get_cursor_position(session->term, x, y);
    return true;
}

static const SeatVtable bridge_seat_vt = {
    .output = bridge_seat_output,
    .eof = bridge_seat_eof,
    .sent = nullseat_sent,
    .banner = nullseat_banner_to_stderr,
    .get_userpass_input = bridge_seat_get_userpass_input,
    .notify_session_started = nullseat_notify_session_started,
    .notify_remote_exit = bridge_seat_notify_remote_exit,
    .notify_remote_disconnect = nullseat_notify_remote_disconnect,
    .connection_fatal = bridge_seat_connection_fatal,
    .nonfatal = bridge_seat_nonfatal,
    .update_specials_menu = nullseat_update_specials_menu,
    .get_ttymode = bridge_seat_get_ttymode,
    .set_busy_status = nullseat_set_busy_status,
    .confirm_ssh_host_key = nullseat_confirm_ssh_host_key,
    .confirm_weak_crypto_primitive = nullseat_confirm_weak_crypto_primitive,
    .confirm_weak_cached_hostkey = nullseat_confirm_weak_cached_hostkey,
    .prompt_descriptions = nullseat_prompt_descriptions,
    .is_utf8 = bridge_seat_is_utf8,
    .echoedit_update = nullseat_echoedit_update,
    .get_display = nullseat_get_display,
    .get_windowid = nullseat_get_windowid,
    .get_window_pixel_size = nullseat_get_window_pixel_size,
    .stripctrl_new = nullseat_stripctrl_new,
    .set_trust_status = bridge_seat_set_trust_status,
    .can_set_trust_status = bridge_seat_can_set_trust_status,
    .has_mixed_input_stream = nullseat_has_mixed_input_stream_yes,
    .verbose = nullseat_verbose_yes,
    .interactive = nullseat_interactive_yes,
    .get_cursor_position = bridge_seat_get_cursor_position,
};

/* --- LogPolicy (stderr-only stub until Phase 5) --- */

static void bridge_logpolicy_eventlog(LogPolicy *lp, const char *event)
{
    (void)lp;
    (void)event;
}

static int bridge_logpolicy_askappend(
    LogPolicy *lp, Filename *filename,
    void (*callback)(void *ctx, int result), void *ctx)
{
    (void)lp; (void)filename; (void)callback; (void)ctx;
    return 2; /* overwrite */
}

static void bridge_logpolicy_logging_error(LogPolicy *lp, const char *event)
{
    PuttySession *session = container_of(lp, PuttySession, logpolicy);
    seat_stderr_pl(&session->seat, ptrlen_from_asciz(event));
    seat_stderr_pl(&session->seat, PTRLEN_LITERAL("\r\n"));
}

static const LogPolicyVtable bridge_logpolicy_vt = {
    .eventlog = bridge_logpolicy_eventlog,
    .askappend = bridge_logpolicy_askappend,
    .logging_error = bridge_logpolicy_logging_error,
    .verbose = null_lp_verbose_yes,
};

/* --- Public API --- */

void putty_session_set_callbacks(
    PuttySession *session,
    const PuttySessionCallbacks *callbacks,
    void *ctx)
{
    PUTTY_BRIDGE_ASSERT_MAIN_THREAD();
    if (!session)
        return;
    if (callbacks)
        session->callbacks = *callbacks;
    else
        memset(&session->callbacks, 0, sizeof(session->callbacks));
    session->callback_ctx = ctx;
}

PuttySession *putty_session_new(const PuttyConf *conf)
{
    PUTTY_BRIDGE_ASSERT_MAIN_THREAD();
    PuttySession *session = snew(PuttySession);

    memset(session, 0, sizeof(*session));
    session->seat.vt = &bridge_seat_vt;
    session->termwin.vt = &bridge_termwin_vt;
    session->logpolicy.vt = &bridge_logpolicy_vt;
    session->conf = session_new_conf(conf);
    session->exited = false;
    session->started = false;

    init_ucs_generic(session->conf, &session->ucsdata);
    session->term = term_init(session->conf, &session->ucsdata, &session->termwin);
    session->logctx = log_init(&session->logpolicy, session->conf);
    term_provide_logctx(session->term, session->logctx);
    term_size(session->term,
              conf_get_int(session->conf, CONF_height),
              conf_get_int(session->conf, CONF_width),
              conf_get_int(session->conf, CONF_savelines));

    return session;
}

void putty_session_free(PuttySession *session)
{
    PUTTY_BRIDGE_ASSERT_MAIN_THREAD();
    if (!session)
        return;

    if (session->started)
        session_destroy_connection(session);

    if (session->term) {
        term_free(session->term);
        session->term = NULL;
    }
    if (session->logctx) {
        log_free(session->logctx);
        session->logctx = NULL;
    }
    if (session->conf) {
        conf_free(session->conf);
        session->conf = NULL;
    }

    sfree(session);
}

void putty_session_start(PuttySession *session)
{
    PUTTY_BRIDGE_ASSERT_MAIN_THREAD();
    const struct BackendVtable *vt;
    char *error, *realhost;

    if (!session || session->started || session->exited)
        return;

    sk_init();

    session->cmdline_get_passwd_state = cmdline_get_passwd_input_state_new;
    prepare_session(session->conf);

    vt = select_backend(session->conf);
    seat_set_trust_status(&session->seat, true);
    error = backend_init(
        vt, &session->seat, &session->backend, session->logctx, session->conf,
        conf_get_str(session->conf, CONF_host),
        conf_get_int(session->conf, CONF_port),
        &realhost,
        conf_get_bool(session->conf, CONF_tcp_nodelay),
        conf_get_bool(session->conf, CONF_tcp_keepalives));

    if (error) {
        seat_connection_fatal(&session->seat,
                              "Unable to open connection to %s:\n%s",
                              conf_dest(session->conf), error);
        sfree(error);
        return;
    }

    term_setup_window_titles(session->term, realhost);
    sfree(realhost);

    term_provide_backend(session->term, session->backend);
    session->ldisc = ldisc_create(
        session->conf, session->term, session->backend, &session->seat);
    session->started = true;
    session->exited = false;

    if (session->ldisc)
        ldisc_echoedit_update(session->ldisc);
}

void putty_session_reconfigure(PuttySession *session, const PuttyConf *conf)
{
    PUTTY_BRIDGE_ASSERT_MAIN_THREAD();
    Conf *newconf, *oldconf;

    if (!session || !conf)
        return;

    newconf = putty_bridge_conf_copy(conf);
    if (!newconf)
        return;

    oldconf = session->conf;
    session->conf = newconf;

    if (session->logctx)
        log_reconfig(session->logctx, session->conf);
    if (session->ldisc) {
        ldisc_configure(session->ldisc, session->conf);
        ldisc_echoedit_update(session->ldisc);
    }
    if (session->term)
        term_reconfig(session->term, session->conf);
    if (session->backend)
        backend_reconfig(session->backend, session->conf);

    conf_free(oldconf);
}

bool putty_session_has_backend(const PuttySession *session)
{
    PUTTY_BRIDGE_ASSERT_MAIN_THREAD();
    return session != NULL && session->backend != NULL;
}

void putty_session_backend_unthrottle(PuttySession *session, size_t bufsize)
{
    PUTTY_BRIDGE_ASSERT_MAIN_THREAD();
    if (!session || !session->backend)
        return;
    backend_unthrottle(session->backend, bufsize);
}

static void putty_bridge_session_smoke_on_output(
    void *ctx, const void *data, size_t len)
{
    size_t *n = ctx;
    (void)data;
    if (n)
        *n += len;
}

static void putty_bridge_session_smoke_on_title(
    void *ctx, const char *title)
{
    (void)ctx;
    (void)title;
}

static void putty_bridge_session_smoke_on_bell(void *ctx, int mode)
{
    (void)ctx;
    (void)mode;
}

static void putty_bridge_session_smoke_on_exit(void *ctx)
{
    (void)ctx;
}

static void putty_bridge_session_smoke_on_redraw(
    void *ctx, PuttyBridgeRect dirty)
{
    (void)ctx;
    (void)dirty;
}

int putty_bridge_session_smoke(void)
{
    PUTTY_BRIDGE_ASSERT_MAIN_THREAD();
    PuttySession *session;
    PuttyConf *conf;
    PuttySessionCallbacks cbs;
    size_t output_bytes = 0;
    static const char probe[] = "session-smoke\r\n";

    session = putty_session_new(NULL);
    if (!session->term || !session->conf)
        return -2;

    memset(&cbs, 0, sizeof(cbs));
    cbs.on_output = putty_bridge_session_smoke_on_output;
    cbs.on_title_changed = putty_bridge_session_smoke_on_title;
    cbs.on_bell = putty_bridge_session_smoke_on_bell;
    cbs.on_exit = putty_bridge_session_smoke_on_exit;
    cbs.on_request_redraw = putty_bridge_session_smoke_on_redraw;
    putty_session_set_callbacks(session, &cbs, &output_bytes);

    conf = putty_conf_new();
    putty_conf_set_host(conf, "session-smoke.example");
    putty_conf_set_port(conf, 2222);
    putty_conf_set_protocol(conf, PUTTY_CONF_PROT_SSH);
    putty_session_reconfigure(session, conf);
    putty_conf_free(conf);

    if (putty_session_output(session, probe, sizeof(probe) - 1) != 0) {
        putty_session_free(session);
        return -4;
    }
    if (putty_session_has_backend(session)) {
        putty_session_free(session);
        return -5;
    }

    putty_session_set_callbacks(session, NULL, NULL);
    putty_session_free(session);
    return 0;
}
