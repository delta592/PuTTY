/*
 * macos/platform/seat.c — MacGuiSeat SeatVtable and LogPolicyVtable (Phase 5.1).
 */

#include <assert.h>
#include <string.h>

#include "seat.h"
#include "seat-dialogs.h"

#include "platform.h"

struct MacGuiSeatListNode mac_gui_seat_list_head = { &mac_gui_seat_list_head,
                                                     &mac_gui_seat_list_head };

static const SeatVtable mac_gui_seat_vt;
static const LogPolicyVtable mac_gui_logpolicy_vt;

static MacGuiSeat *seat_from_seat(Seat *seat)
{
    return container_of(seat, MacGuiSeat, seat);
}

static MacGuiSeat *seat_from_logpolicy(LogPolicy *lp)
{
    return container_of(lp, MacGuiSeat, logpolicy);
}

static void mac_gui_seat_link(MacGuiSeat *seat)
{
    seat->listnode.prev = mac_gui_seat_list_head.prev;
    seat->listnode.next = &mac_gui_seat_list_head;
    seat->listnode.prev->next = &seat->listnode;
    seat->listnode.next->prev = &seat->listnode;
}

static void mac_gui_seat_unlink(MacGuiSeat *seat)
{
    seat->listnode.prev->next = seat->listnode.next;
    seat->listnode.next->prev = seat->listnode.prev;
}

static Conf *mac_gui_seat_new_conf(const Conf *conf)
{
    Conf *copy;

    if (conf)
        return conf_copy((Conf *)conf);

    copy = conf_new();
    do_defaults(NULL, copy);
    return copy;
}

static void mac_gui_seat_setup_clipboards(MacGuiSeat *seat)
{
    Terminal *term = seat->term;
    Conf *conf = seat->conf;

    assert(term->mouse_select_clipboards[0] == CLIP_LOCAL);

    term->n_mouse_select_clipboards = 1;
    term->mouse_select_clipboards[term->n_mouse_select_clipboards++] =
        MOUSE_SELECT_CLIPBOARD;

    if (conf_get_bool(conf, CONF_mouseautocopy)) {
        term->mouse_select_clipboards[term->n_mouse_select_clipboards++] =
            CLIP_CLIPBOARD;
    }

    switch (conf_get_int(conf, CONF_mousepaste)) {
      case CLIPUI_IMPLICIT:
        term->mouse_paste_clipboard = MOUSE_PASTE_CLIPBOARD;
        break;
      case CLIPUI_EXPLICIT:
        term->mouse_paste_clipboard = CLIP_CLIPBOARD;
        break;
      case CLIPUI_CUSTOM:
        term->mouse_paste_clipboard = CLIP_CUSTOM_1;
        break;
      default:
        term->mouse_paste_clipboard = CLIP_NULL;
        break;
    }
}

static void mac_gui_seat_exit_callback(void *vctx)
{
    MacGuiSeat *seat = (MacGuiSeat *)vctx;
    int exitcode = -1;

    if (seat->backend)
        exitcode = backend_exitcode(seat->backend);

    if (seat->callbacks.on_remote_exit)
        seat->callbacks.on_remote_exit(seat->callback_ctx, exitcode);
}

static void mac_gui_seat_queue_exit(MacGuiSeat *seat)
{
    queue_toplevel_callback(mac_gui_seat_exit_callback, seat);
}

void mac_gui_seat_flush_display(MacGuiSeat *seat)
{
    if (!seat)
        return;

    while (run_toplevel_callbacks())
        ;
}

static void mac_gui_seat_request_redraw(MacGuiSeat *seat)
{
    if (!seat || !seat->term)
        return;

    win_refresh(mac_termwin_get_termwin(&seat->termwin));
}

/* --- SeatVtable --- */

static size_t mac_seat_output(
    Seat *seat, SeatOutputType type, const void *data, size_t len)
{
    MacGuiSeat *mgs = seat_from_seat(seat);
    size_t backlog;

    (void)type;
    if (!mgs->term || !data || len == 0)
        return 0;

    backlog = term_data(mgs->term, data, len);
    mac_gui_seat_flush_display(mgs);
    mac_gui_seat_request_redraw(mgs);
    return backlog;
}

static size_t mac_seat_banner(
    Seat *seat, const void *data, size_t len)
{
    return mac_seat_output(seat, SEAT_OUTPUT_STDERR, data, len);
}

static bool mac_seat_eof(Seat *seat)
{
    (void)seat;
    return true;
}

static SeatPromptResult mac_seat_get_userpass_input(Seat *seat, prompts_t *p)
{
    MacGuiSeat *mgs = seat_from_seat(seat);
    SeatPromptResult spr;

    spr = cmdline_get_passwd_input(
        p, &mgs->cmdline_get_passwd_state, true);
    if (spr.kind != SPRK_INCOMPLETE)
        return spr;
    return mac_seat_get_userpass_input_dialog(p);
}

static void mac_seat_notify_remote_exit(Seat *seat)
{
    MacGuiSeat *mgs = seat_from_seat(seat);
    int exitcode;

    if (!mgs->exited &&
        mgs->backend &&
        (exitcode = backend_exitcode(mgs->backend)) >= 0) {
        mac_gui_seat_destroy_connection(mgs);
        mac_gui_seat_queue_exit(mgs);
    }
}

static void mac_seat_connection_fatal(Seat *seat, const char *msg)
{
    MacGuiSeat *mgs = seat_from_seat(seat);
    char *title = dupprintf("%s Fatal Error", appname);

    if (mgs->callbacks.on_connection_fatal)
        mgs->callbacks.on_connection_fatal(mgs->callback_ctx, msg);
    else
        mac_seat_show_connection_fatal(title, msg, NULL_HELPCTX);
    sfree(title);

    mgs->exited = true;
    mac_gui_seat_destroy_connection(mgs);
    mac_gui_seat_queue_exit(mgs);
}

static void mac_seat_nonfatal(Seat *seat, const char *msg)
{
    MacGuiSeat *mgs = seat_from_seat(seat);
    char *title = dupprintf("%s Error", appname);

    if (mgs->callbacks.on_nonfatal)
        mgs->callbacks.on_nonfatal(mgs->callback_ctx, msg);
    else
        mac_seat_show_nonfatal(title, msg, NULL_HELPCTX);
    sfree(title);
}

static void mac_seat_update_specials_menu(Seat *seat)
{
    MacGuiSeat *mgs = seat_from_seat(seat);

    if (mgs->callbacks.on_update_specials_menu)
        mgs->callbacks.on_update_specials_menu(mgs->callback_ctx);
}

static char *mac_seat_get_ttymode(Seat *seat, const char *mode)
{
    MacGuiSeat *mgs = seat_from_seat(seat);

    if (!mgs->term)
        return NULL;
    return term_get_ttymode(mgs->term, mode);
}

static void mac_seat_set_busy_status(Seat *seat, BusyStatus status)
{
    MacGuiSeat *mgs = seat_from_seat(seat);

    mgs->busy_status = status;
    if (mgs->callbacks.on_set_busy_status)
        mgs->callbacks.on_set_busy_status(mgs->callback_ctx, status);
}

static bool mac_seat_is_utf8(Seat *seat)
{
    MacGuiSeat *mgs = seat_from_seat(seat);
    return mgs->ucsdata.line_codepage == CS_UTF8;
}

static bool mac_seat_get_window_pixel_size(Seat *seat, int *w, int *h)
{
    MacGuiSeat *mgs = seat_from_seat(seat);

    if (!mgs->term)
        return false;

    *w = (int)(mgs->term->cols * mgs->termwin.cell_width_pt);
    *h = (int)(mgs->term->rows * mgs->termwin.cell_height_pt);
    return true;
}

static StripCtrlChars *mac_seat_stripctrl_new(
    Seat *seat, BinarySink *bs_out, SeatInteractionContext sic)
{
    MacGuiSeat *mgs = seat_from_seat(seat);

    if (!mgs->term)
        return NULL;
    return stripctrl_new_term(bs_out, false, 0, mgs->term);
}

static void mac_seat_set_trust_status(Seat *seat, bool trusted)
{
    MacGuiSeat *mgs = seat_from_seat(seat);

    if (mgs->term)
        term_set_trust_status(mgs->term, trusted);
}

static bool mac_seat_can_set_trust_status(Seat *seat)
{
    (void)seat;
    return true;
}

static bool mac_seat_get_cursor_position(Seat *seat, int *x, int *y)
{
    MacGuiSeat *mgs = seat_from_seat(seat);

    if (!mgs->term)
        return false;
    term_get_cursor_position(mgs->term, x, y);
    return true;
}

static void mac_seat_echoedit_update(Seat *seat, bool echoing, bool editing)
{
    MacGuiSeat *mgs = seat_from_seat(seat);
    bool changed;

    changed = (mgs->echoing != echoing || mgs->editing != editing);
    mgs->echoing = echoing;
    mgs->editing = editing;

    if (mgs->callbacks.on_echoedit_update)
        mgs->callbacks.on_echoedit_update(
            mgs->callback_ctx, echoing, editing);

    if (changed && mgs->term) {
        term_invalidate(mgs->term);
        mac_gui_seat_flush_display(mgs);
        mac_gui_seat_request_redraw(mgs);
    }
}

static const SeatVtable mac_gui_seat_vt = {
    .output = mac_seat_output,
    .eof = mac_seat_eof,
    .sent = nullseat_sent,
    .banner = mac_seat_banner,
    .get_userpass_input = mac_seat_get_userpass_input,
    .notify_session_started = nullseat_notify_session_started,
    .notify_remote_exit = mac_seat_notify_remote_exit,
    .notify_remote_disconnect = nullseat_notify_remote_disconnect,
    .connection_fatal = mac_seat_connection_fatal,
    .nonfatal = mac_seat_nonfatal,
    .update_specials_menu = mac_seat_update_specials_menu,
    .get_ttymode = mac_seat_get_ttymode,
    .set_busy_status = mac_seat_set_busy_status,
    .confirm_ssh_host_key = mac_seat_confirm_ssh_host_key,
    .confirm_weak_crypto_primitive = mac_seat_confirm_weak_crypto_primitive,
    .confirm_weak_cached_hostkey = mac_seat_confirm_weak_cached_hostkey,
    .prompt_descriptions = mac_seat_prompt_descriptions,
    .is_utf8 = mac_seat_is_utf8,
    .echoedit_update = mac_seat_echoedit_update,
    .get_display = nullseat_get_display,
    .get_windowid = nullseat_get_windowid,
    .get_window_pixel_size = mac_seat_get_window_pixel_size,
    .stripctrl_new = mac_seat_stripctrl_new,
    .set_trust_status = mac_seat_set_trust_status,
    .can_set_trust_status = mac_seat_can_set_trust_status,
    .has_mixed_input_stream = nullseat_has_mixed_input_stream_yes,
    .verbose = nullseat_verbose_yes,
    .interactive = nullseat_interactive_yes,
    .get_cursor_position = mac_seat_get_cursor_position,
};

/* --- LogPolicyVtable --- */

static void mac_logpolicy_eventlog(LogPolicy *lp, const char *event)
{
    MacGuiSeat *mgs = seat_from_logpolicy(lp);

    if (mgs->callbacks.on_eventlog)
        mgs->callbacks.on_eventlog(mgs->callback_ctx, event);
}

static int mac_logpolicy_askappend(
    LogPolicy *lp, Filename *filename,
    void (*callback)(void *ctx, int result), void *ctx)
{
    MacGuiSeat *mgs = seat_from_logpolicy(lp);
    const char *path;

    if (mgs->callbacks.on_askappend) {
        path = filename_to_str(filename);
        return mgs->callbacks.on_askappend(
            mgs->callback_ctx, path, callback, ctx);
    }

    (void)callback;
    (void)ctx;
    return 2; /* overwrite when no UI is wired yet */
}

static void mac_logpolicy_logging_error(LogPolicy *lp, const char *event)
{
    MacGuiSeat *mgs = seat_from_logpolicy(lp);

    seat_stderr_pl(&mgs->seat, ptrlen_from_asciz(event));
    seat_stderr_pl(&mgs->seat, PTRLEN_LITERAL("\r\n"));
}

static const LogPolicyVtable mac_gui_logpolicy_vt = {
    .eventlog = mac_logpolicy_eventlog,
    .askappend = mac_logpolicy_askappend,
    .logging_error = mac_logpolicy_logging_error,
    .verbose = null_lp_verbose_yes,
};

/* --- Public API --- */

void mac_gui_seat_set_callbacks(
    MacGuiSeat *seat, const MacGuiSeatCallbacks *callbacks, void *ctx)
{
    if (!seat)
        return;
    if (callbacks)
        seat->callbacks = *callbacks;
    else
        memset(&seat->callbacks, 0, sizeof(seat->callbacks));
    seat->callback_ctx = ctx;
}

MacGuiSeat *mac_gui_seat_new(const Conf *conf)
{
    MacGuiSeat *seat = snew(MacGuiSeat);

    memset(seat, 0, sizeof(*seat));
    seat->seat.vt = &mac_gui_seat_vt;
    seat->logpolicy.vt = &mac_gui_logpolicy_vt;

    mac_termwin_init(&seat->termwin);

    seat->conf = mac_gui_seat_new_conf(conf);
    init_ucs_generic(seat->conf, &seat->ucsdata);

    mac_termwin_set_conf(&seat->termwin, seat->conf);
    seat->term = term_init(
        seat->conf, &seat->ucsdata, mac_termwin_get_termwin(&seat->termwin));
    if (!seat->term) {
        conf_free(seat->conf);
        sfree(seat);
        return NULL;
    }

    mac_termwin_set_terminal(&seat->termwin, seat->term);
    mac_gui_seat_setup_clipboards(seat);

    seat->logctx = log_init(&seat->logpolicy, seat->conf);
    term_provide_logctx(seat->term, seat->logctx);
    term_size(seat->term,
              conf_get_int(seat->conf, CONF_height),
              conf_get_int(seat->conf, CONF_width),
              conf_get_int(seat->conf, CONF_savelines));

    seat->started = false;
    seat->exited = false;
    mac_gui_seat_link(seat);

    return seat;
}

void mac_gui_seat_destroy_connection(MacGuiSeat *seat)
{
    if (!seat)
        return;

    seat->exited = true;
    if (seat->ldisc) {
        ldisc_free(seat->ldisc);
        seat->ldisc = NULL;
    }
    if (seat->backend) {
        if (seat->backend->vt != &null_backend)
            backend_free(seat->backend);
        seat->backend = NULL;
    }
    if (seat->term)
        term_provide_backend(seat->term, NULL);
    mac_termwin_set_backend(&seat->termwin, NULL);
    seat->started = false;
    seat_update_specials_menu(&seat->seat);
}

void mac_gui_seat_free(MacGuiSeat *seat)
{
    if (!seat)
        return;

    mac_gui_seat_unlink(seat);

    if (seat->started)
        mac_gui_seat_destroy_connection(seat);

    if (seat->term) {
        term_free(seat->term);
        seat->term = NULL;
    }
    if (seat->logctx) {
        log_free(seat->logctx);
        seat->logctx = NULL;
    }
    if (seat->conf) {
        conf_free(seat->conf);
        seat->conf = NULL;
    }

    mac_termwin_destroy(&seat->termwin);
    sfree(seat);
}

bool mac_gui_seat_start(MacGuiSeat *seat)
{
    const struct BackendVtable *vt;
    char *error, *realhost;

    if (!seat || seat->started || seat->exited)
        return false;

    sk_init();

    seat->cmdline_get_passwd_state = cmdline_get_passwd_input_state_new;
    prepare_session(seat->conf);

    vt = select_backend(seat->conf);
    seat_set_trust_status(&seat->seat, true);
    error = backend_init(
        vt, &seat->seat, &seat->backend, seat->logctx, seat->conf,
        conf_get_str(seat->conf, CONF_host),
        conf_get_int(seat->conf, CONF_port),
        &realhost,
        conf_get_bool(seat->conf, CONF_tcp_nodelay),
        conf_get_bool(seat->conf, CONF_tcp_keepalives));

    if (error) {
        seat_connection_fatal(
            &seat->seat,
            "Unable to open connection to %s:\n%s",
            conf_dest(seat->conf), error);
        sfree(error);
        return false;
    }

    term_setup_window_titles(seat->term, realhost);
    sfree(realhost);

    term_provide_backend(seat->term, seat->backend);
    mac_termwin_set_backend(&seat->termwin, seat->backend);

    seat->ldisc = ldisc_create(
        seat->conf, seat->term, seat->backend, &seat->seat);
    if (!seat->ldisc) {
        mac_gui_seat_destroy_connection(seat);
        return false;
    }

    seat->started = true;
    seat->exited = false;
    ldisc_echoedit_update(seat->ldisc);
    return true;
}

bool mac_gui_seat_start_local_echo(MacGuiSeat *seat)
{
    if (!seat || seat->started || seat->exited)
        return false;

    conf_set_int(seat->conf, CONF_localecho, FORCE_ON);
    conf_set_int(seat->conf, CONF_localedit, FORCE_OFF);

    seat->null_backend.vt = &null_backend;
    seat->backend = &seat->null_backend;

    term_provide_backend(seat->term, seat->backend);
    mac_termwin_set_backend(&seat->termwin, seat->backend);

    seat->ldisc = ldisc_create(
        seat->conf, seat->term, seat->backend, &seat->seat);
    if (!seat->ldisc)
        return false;

    seat->started = true;
    seat->exited = false;
    ldisc_echoedit_update(seat->ldisc);
    return true;
}

void mac_gui_seat_reconfigure(MacGuiSeat *seat, const Conf *conf)
{
    Conf *newconf, *oldconf;

    if (!seat || !conf)
        return;

    newconf = conf_copy((Conf *)conf);
    if (!newconf)
        return;

    oldconf = seat->conf;
    seat->conf = newconf;
    mac_termwin_set_conf(&seat->termwin, seat->conf);
    mac_gui_seat_setup_clipboards(seat);

    if (seat->logctx)
        log_reconfig(seat->logctx, seat->conf);
    if (seat->ldisc) {
        ldisc_configure(seat->ldisc, seat->conf);
        ldisc_echoedit_update(seat->ldisc);
    }
    if (seat->term)
        term_reconfig(seat->term, seat->conf);
    if (seat->backend && seat->backend->vt != &null_backend)
        backend_reconfig(seat->backend, seat->conf);

    conf_free(oldconf);
}

Seat *mac_gui_seat_get_seat(MacGuiSeat *seat)
{
    return seat ? &seat->seat : NULL;
}

MacTermWin *mac_gui_seat_get_termwin(MacGuiSeat *seat)
{
    return seat ? &seat->termwin : NULL;
}

Terminal *mac_gui_seat_get_terminal(MacGuiSeat *seat)
{
    return seat ? seat->term : NULL;
}

Backend *mac_gui_seat_get_backend(MacGuiSeat *seat)
{
    return seat ? seat->backend : NULL;
}

Ldisc *mac_gui_seat_get_ldisc(MacGuiSeat *seat)
{
    return seat ? seat->ldisc : NULL;
}

Conf *mac_gui_seat_get_conf(MacGuiSeat *seat)
{
    return seat ? seat->conf : NULL;
}

LogContext *mac_gui_seat_get_logctx(MacGuiSeat *seat)
{
    return seat ? seat->logctx : NULL;
}

int mac_gui_seat_smoke(void)
{
    MacGuiSeat *seat;
    static const char banner[] = "MacGuiSeat smoke\r\n";

    seat = mac_gui_seat_new(NULL);
    if (!seat)
        return 1;
    if (!seat->term || !seat->conf)
        return 2;
    if (mac_gui_seat_get_termwin(seat) != &seat->termwin)
        return 3;
    if (mac_termwin_from_termwin(mac_termwin_get_termwin(&seat->termwin)) !=
        &seat->termwin)
        return 4;
    if (!mac_gui_seat_start_local_echo(seat))
        return 5;
    if (!mac_gui_seat_get_ldisc(seat))
        return 6;

    seat_output(
        mac_gui_seat_get_seat(seat), SEAT_OUTPUT_STDOUT,
        banner, sizeof(banner) - 1);

    term_update(seat->term);
    if (seat->term->rows < 1 || seat->term->cols < 1)
        return 7;
    mac_gui_seat_free(seat);
    return 0;
}

struct mac_gui_seat_output_smoke_ctx {
    MacGuiSeat *seat;
    int redraw_requests;
};

static void mac_gui_seat_output_smoke_redraw(
    void *ctx, MacTermWinRect dirty)
{
    struct mac_gui_seat_output_smoke_ctx *test =
        (struct mac_gui_seat_output_smoke_ctx *)ctx;

    (void)dirty;
    test->redraw_requests++;
}

static bool mac_gui_seat_output_smoke_term_has_text(
    Terminal *term, int x, int y, wchar_t expect)
{
    termline *tl = term_get_line(term, y);
    bool found = false;

    if (tl && 0 <= x && x < tl->cols)
        found = (tl->chars[x].chr == expect);
    term_release_line(tl);
    return found;
}

int mac_gui_seat_output_smoke(void)
{
    MacGuiSeat *seat;
    struct mac_gui_seat_output_smoke_ctx test_ctx;
    MacTermWinCallbacks callbacks;
    static const char banner[] = "MacGuiSeat output\r\n";

    seat = mac_gui_seat_new(NULL);
    if (!seat)
        return 1;
    if (!mac_gui_seat_start_local_echo(seat))
        return 2;

    memset(&test_ctx, 0, sizeof(test_ctx));
    test_ctx.seat = seat;
    memset(&callbacks, 0, sizeof(callbacks));
    callbacks.request_redraw = mac_gui_seat_output_smoke_redraw;
    mac_termwin_set_callbacks(mac_gui_seat_get_termwin(seat), &callbacks, &test_ctx);

    seat_output(
        mac_gui_seat_get_seat(seat), SEAT_OUTPUT_STDOUT,
        banner, sizeof(banner) - 1);
    if (test_ctx.redraw_requests < 1)
        return 3;
    if (!mac_gui_seat_output_smoke_term_has_text(
            seat->term, 0, 0, (wchar_t)(CSET_ASCII | 'M')))
        return 4;

    seat_output(
        mac_gui_seat_get_seat(seat), SEAT_OUTPUT_STDERR,
        "auth banner\r\n", 13);
    if (test_ctx.redraw_requests < 2)
        return 5;

    seat_echoedit_update(mac_gui_seat_get_seat(seat), false, true);
    if (seat->echoing || !seat->editing)
        return 6;
    if (test_ctx.redraw_requests < 3)
        return 7;

    mac_gui_seat_free(seat);
    return 0;
}
