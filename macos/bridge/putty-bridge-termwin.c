/*
 * putty-bridge-termwin.c — Swift bridge for MacTermWin / TerminalView (Phase 4.2).
 */

#include <stdio.h>
#include <string.h>
#include <time.h>

#include "putty-bridge.h"
#include "putty-bridge-termwin.h"
#include "putty-bridge-internal.h"
#include "putty-bridge-thread.h"
#include "seat.h"
#include "seat-dialogs.h"
#include "termwin.h"
#include "osxkeys.h"
#include "terminal.h"
#include "platform.h"
#include "misc.h"
#include "config-appkit.h"

#define LOGEVENT_INITIAL_MAX 128
#define LOGEVENT_CIRCULAR_MAX 128

struct PuttyBridgeTermWin {
    MacGuiSeat *seat;
    MacTermWin *mtw;
    Conf *conf;
    Terminal *term;
    struct unicode_data ucsdata;
    bool demo_initialised;
    bool session_initialised;
    PuttyBridgeTermWinCallbacks swift_callbacks;
    void *swift_view_ctx;
    PuttyBridgeSpecialsMenuCallback specials_menu_callback;
    void *specials_menu_ctx;
    PuttyBridgeEventLogCallback eventlog_callback;
    void *eventlog_ctx;
    PuttyBridgeRemoteExitCallback remote_exit_callback;
    void *remote_exit_ctx;
    char **events_initial;
    char **events_circular;
    int ninitial, ncircular, circular_first;
    Seat demo_seat;
    Backend demo_backend;
    Ldisc *demo_ldisc;
};

static PuttyBridgeOptionalRgb bridge_optional_rgb(optionalrgb rgb)
{
    PuttyBridgeOptionalRgb out;

    out.enabled = rgb.enabled;
    out.r = rgb.r;
    out.g = rgb.g;
    out.b = rgb.b;
    return out;
}

static PuttyBridgeTermWinDrawParams bridge_draw_params(
    const MacTermWinDrawParams *params)
{
    PuttyBridgeTermWinDrawParams out;

    out.x = params->x;
    out.y = params->y;
    out.text = params->text;
    out.len = params->len;
    out.attr = (uint32_t)params->attr;
    out.lattr = params->lattr;
    out.truecolour.fg = bridge_optional_rgb(params->tc.fg);
    out.truecolour.bg = bridge_optional_rgb(params->tc.bg);
    return out;
}

static bool bridge_setup_draw_ctx(void *ctx)
{
    PuttyBridgeTermWin *btw = (PuttyBridgeTermWin *)ctx;

    /*
     * Headless smokes omit Swift setup_draw_ctx. Still allow term_update
     * so update_sbar / cursor bookkeeping run (draw_* callbacks no-op).
     * Production TerminalView always registers setup_draw_ctx and returns
     * false outside draw(_:) so paint is deferred to AppKit.
     */
    if (!btw->swift_callbacks.setup_draw_ctx)
        return true;
    return btw->swift_callbacks.setup_draw_ctx(btw->swift_view_ctx);
}

static void bridge_free_draw_ctx(void *ctx)
{
    PuttyBridgeTermWin *btw = (PuttyBridgeTermWin *)ctx;

    if (btw->swift_callbacks.free_draw_ctx)
        btw->swift_callbacks.free_draw_ctx(btw->swift_view_ctx);
}

static void bridge_draw_text(void *ctx, const MacTermWinDrawParams *params)
{
    PuttyBridgeTermWin *btw = (PuttyBridgeTermWin *)ctx;
    PuttyBridgeTermWinDrawParams swift_params;

    if (!btw->swift_callbacks.draw_text)
        return;

    swift_params = bridge_draw_params(params);
    btw->swift_callbacks.draw_text(btw->swift_view_ctx, &swift_params);
}

static void bridge_draw_cursor(void *ctx, const MacTermWinDrawParams *params)
{
    PuttyBridgeTermWin *btw = (PuttyBridgeTermWin *)ctx;
    PuttyBridgeTermWinDrawParams swift_params;

    if (!btw->swift_callbacks.draw_cursor)
        return;

    swift_params = bridge_draw_params(params);
    btw->swift_callbacks.draw_cursor(btw->swift_view_ctx, &swift_params);
}

static void bridge_draw_trust_sigil(void *ctx, int x, int y)
{
    PuttyBridgeTermWin *btw = (PuttyBridgeTermWin *)ctx;

    if (btw->swift_callbacks.draw_trust_sigil)
        btw->swift_callbacks.draw_trust_sigil(btw->swift_view_ctx, x, y);
}

static void bridge_request_redraw(void *ctx, MacTermWinRect dirty)
{
    PuttyBridgeTermWin *btw = (PuttyBridgeTermWin *)ctx;
    PuttyBridgeTermWinRect swift_dirty;

    if (!btw->swift_callbacks.request_redraw)
        return;

    swift_dirty.x = dirty.x;
    swift_dirty.y = dirty.y;
    swift_dirty.width = dirty.width;
    swift_dirty.height = dirty.height;
    btw->swift_callbacks.request_redraw(btw->swift_view_ctx, swift_dirty);
}

static int bridge_char_width(void *ctx, int uc)
{
    PuttyBridgeTermWin *btw = (PuttyBridgeTermWin *)ctx;

    if (btw->swift_callbacks.char_width)
        return btw->swift_callbacks.char_width(btw->swift_view_ctx, uc);
    return 1;
}

static void bridge_set_cursor_pos(void *ctx, int x, int y)
{
    PuttyBridgeTermWin *btw = (PuttyBridgeTermWin *)ctx;

    if (btw->swift_callbacks.set_cursor_pos)
        btw->swift_callbacks.set_cursor_pos(btw->swift_view_ctx, x, y);
}

static void bridge_set_raw_mouse_mode(void *ctx, bool enable)
{
    PuttyBridgeTermWin *btw = (PuttyBridgeTermWin *)ctx;

    if (btw->swift_callbacks.set_raw_mouse_mode)
        btw->swift_callbacks.set_raw_mouse_mode(btw->swift_view_ctx, enable);
}

static void bridge_set_raw_mouse_mode_pointer(void *ctx, bool enable)
{
    PuttyBridgeTermWin *btw = (PuttyBridgeTermWin *)ctx;

    if (btw->swift_callbacks.set_raw_mouse_mode_pointer)
        btw->swift_callbacks.set_raw_mouse_mode_pointer(
            btw->swift_view_ctx, enable);
}

static void bridge_clip_write(
    void *ctx, int clipboard, wchar_t *text, int *attrs,
    truecolour *colours, int len, bool must_deselect)
{
    PuttyBridgeTermWin *btw = (PuttyBridgeTermWin *)ctx;

    (void)attrs;
    (void)colours;
    if (!btw->swift_callbacks.clip_write)
        return;
    btw->swift_callbacks.clip_write(
        btw->swift_view_ctx, clipboard, text, len, must_deselect);
}

static void bridge_clip_request_paste(void *ctx, int clipboard)
{
    PuttyBridgeTermWin *btw = (PuttyBridgeTermWin *)ctx;

    if (btw->swift_callbacks.clip_request_paste)
        btw->swift_callbacks.clip_request_paste(btw->swift_view_ctx, clipboard);
}

static void bridge_set_scrollbar(void *ctx, int total, int start, int page)
{
    PuttyBridgeTermWin *btw = (PuttyBridgeTermWin *)ctx;

    if (btw->swift_callbacks.set_scrollbar)
        btw->swift_callbacks.set_scrollbar(
            btw->swift_view_ctx, total, start, page);
}

static void bridge_request_resize(void *ctx, int w, int h)
{
    PuttyBridgeTermWin *btw = (PuttyBridgeTermWin *)ctx;

    if (btw->swift_callbacks.request_resize)
        btw->swift_callbacks.request_resize(btw->swift_view_ctx, w, h);
}

static char *bridge_decode_title(const char *title, int codepage)
{
    if (!title)
        return dupstr("");

    if (codepage == CP_UTF8)
        return dupstr(title);

    {
        wchar_t *wide = dup_mb_to_wc(codepage, title);
        char *utf8 = encode_wide_string_as_utf8(wide);
        sfree(wide);
        return utf8;
    }
}

static void bridge_bell(void *ctx, int mode)
{
    PuttyBridgeTermWin *btw = (PuttyBridgeTermWin *)ctx;

    if (btw->swift_callbacks.bell)
        btw->swift_callbacks.bell(btw->swift_view_ctx, mode);
}

static void bridge_set_title(void *ctx, const char *title, int codepage)
{
    PuttyBridgeTermWin *btw = (PuttyBridgeTermWin *)ctx;
    char *utf8;

    if (!btw->swift_callbacks.set_title)
        return;

    utf8 = bridge_decode_title(title, codepage);
    btw->swift_callbacks.set_title(btw->swift_view_ctx, utf8);
    sfree(utf8);
}

static void bridge_set_icon_title(void *ctx, const char *title, int codepage)
{
    PuttyBridgeTermWin *btw = (PuttyBridgeTermWin *)ctx;
    char *utf8;

    if (!btw->swift_callbacks.set_icon_title)
        return;

    utf8 = bridge_decode_title(title, codepage);
    btw->swift_callbacks.set_icon_title(btw->swift_view_ctx, utf8);
    sfree(utf8);
}

static size_t bridge_demo_seat_output(
    Seat *seat, SeatOutputType type, const void *data, size_t len)
{
    PuttyBridgeTermWin *btw = container_of(seat, PuttyBridgeTermWin, demo_seat);

    (void)type;
    if (!btw->term || !data || len == 0)
        return 0;
    return term_data(btw->term, data, len);
}

static const SeatVtable bridge_demo_seat_vt = {
    .output = bridge_demo_seat_output,
    .echoedit_update = nullseat_echoedit_update,
};

static Mouse_Button bridge_translate_button(
    PuttyBridgeTermWin *btw, Mouse_Button button)
{
    int mode = MOUSE_COMPROMISE;

    if (btw && btw->conf)
        mode = conf_get_int(btw->conf, CONF_mouse_is_xterm);

    if (button == MBT_LEFT)
        return MBT_SELECT;
    if (button == MBT_MIDDLE)
        return mode == MOUSE_XTERM ? MBT_PASTE : MBT_EXTEND;
    if (button == MBT_RIGHT)
        return mode == MOUSE_XTERM ? MBT_EXTEND : MBT_PASTE;
    if (button == MBT_NOTHING)
        return MBT_NOTHING;
    return button;
}

static void bridge_install_termwin_callbacks(PuttyBridgeTermWin *btw)
{
    static const MacTermWinCallbacks internal_cbs = {
        .setup_draw_ctx = bridge_setup_draw_ctx,
        .free_draw_ctx = bridge_free_draw_ctx,
        .draw_text = bridge_draw_text,
        .draw_cursor = bridge_draw_cursor,
        .draw_trust_sigil = bridge_draw_trust_sigil,
        .char_width = bridge_char_width,
        .request_redraw = bridge_request_redraw,
        .set_cursor_pos = bridge_set_cursor_pos,
        .set_raw_mouse_mode = bridge_set_raw_mouse_mode,
        .set_raw_mouse_mode_pointer = bridge_set_raw_mouse_mode_pointer,
        .clip_write = bridge_clip_write,
        .clip_request_paste = bridge_clip_request_paste,
        .set_scrollbar = bridge_set_scrollbar,
        .request_resize = bridge_request_resize,
        .bell = bridge_bell,
        .set_title = bridge_set_title,
        .set_icon_title = bridge_set_icon_title,
    };

    mac_termwin_set_callbacks(btw->mtw, &internal_cbs, btw);
}

PuttyBridgeTermWin *putty_bridge_termwin_new(void)
{
    PuttyBridgeTermWin *btw = snew(PuttyBridgeTermWin);

    memset(btw, 0, sizeof(*btw));
    return btw;
}

static void bridge_eventlog_free_lines(PuttyBridgeTermWin *btw)
{
    int i;

    if (btw->events_initial) {
        for (i = 0; i < LOGEVENT_INITIAL_MAX; i++)
            sfree(btw->events_initial[i]);
        sfree(btw->events_initial);
        btw->events_initial = NULL;
    }
    if (btw->events_circular) {
        for (i = 0; i < LOGEVENT_CIRCULAR_MAX; i++)
            sfree(btw->events_circular[i]);
        sfree(btw->events_circular);
        btw->events_circular = NULL;
    }
    btw->ninitial = btw->ncircular = btw->circular_first = 0;
}

void putty_bridge_termwin_free(PuttyBridgeTermWin *btw)
{
    if (!btw)
        return;

    /*
     * Detach Swift callbacks before freeing the seat. mac_gui_seat_free →
     * destroy_connection → seat_update_specials_menu must not call into a
     * SessionWindowController that has already been released (app_crash_006).
     */
    btw->specials_menu_callback = NULL;
    btw->specials_menu_ctx = NULL;
    btw->eventlog_callback = NULL;
    btw->eventlog_ctx = NULL;
    btw->remote_exit_callback = NULL;
    btw->remote_exit_ctx = NULL;
    memset(&btw->swift_callbacks, 0, sizeof(btw->swift_callbacks));
    btw->swift_view_ctx = NULL;

    if (btw->seat) {
        mac_gui_seat_free(btw->seat);
        btw->seat = NULL;
        btw->mtw = NULL;
        btw->term = NULL;
        btw->conf = NULL;
        btw->demo_ldisc = NULL;
    } else {
        if (btw->demo_ldisc) {
            ldisc_free(btw->demo_ldisc);
            btw->demo_ldisc = NULL;
        }
        if (btw->term) {
            term_free(btw->term);
            btw->term = NULL;
        }
        if (btw->conf) {
            conf_free(btw->conf);
            btw->conf = NULL;
        }
        if (btw->mtw) {
            mac_termwin_free(btw->mtw);
            btw->mtw = NULL;
        }
    }
    bridge_eventlog_free_lines(btw);
    sfree(btw);
}

void putty_bridge_termwin_set_callbacks(
    PuttyBridgeTermWin *btw,
    const PuttyBridgeTermWinCallbacks *callbacks,
    void *view_ctx)
{
    PUTTY_BRIDGE_ASSERT_MAIN_THREAD();
    if (callbacks)
        btw->swift_callbacks = *callbacks;
    else
        memset(&btw->swift_callbacks, 0, sizeof(btw->swift_callbacks));
    btw->swift_view_ctx = view_ctx;
}

bool putty_bridge_termwin_init_session(PuttyBridgeTermWin *btw)
{
    return putty_bridge_termwin_open(btw, NULL, false);
}

static void bridge_on_update_specials_menu(void *ctx)
{
    PuttyBridgeTermWin *btw = (PuttyBridgeTermWin *)ctx;

    if (btw && btw->specials_menu_callback)
        btw->specials_menu_callback(btw->specials_menu_ctx);
}

static void bridge_eventlog_ensure_storage(PuttyBridgeTermWin *btw)
{
    size_t i;

    if (btw->ninitial != 0 || btw->events_initial)
        return;

    btw->events_initial = sresize(
        btw->events_initial, LOGEVENT_INITIAL_MAX, char *);
    for (i = 0; i < LOGEVENT_INITIAL_MAX; i++)
        btw->events_initial[i] = NULL;
    btw->events_circular = sresize(
        btw->events_circular, LOGEVENT_CIRCULAR_MAX, char *);
    for (i = 0; i < LOGEVENT_CIRCULAR_MAX; i++)
        btw->events_circular[i] = NULL;
}

static void bridge_eventlog_append(
    PuttyBridgeTermWin *btw, const char *string)
{
    char timebuf[40];
    struct tm tm;
    char **location;

    if (!btw || !string)
        return;

    bridge_eventlog_ensure_storage(btw);

    if (btw->ninitial < LOGEVENT_INITIAL_MAX)
        location = &btw->events_initial[btw->ninitial];
    else
        location = &btw->events_circular[
            (btw->circular_first + btw->ncircular) % LOGEVENT_CIRCULAR_MAX];

    tm = ltime();
    strftime(timebuf, sizeof(timebuf), "%Y-%m-%d %H:%M:%S\t", &tm);

    sfree(*location);
    *location = dupcat(timebuf, string);

    if (btw->ninitial < LOGEVENT_INITIAL_MAX) {
        btw->ninitial++;
    } else if (btw->ncircular < LOGEVENT_CIRCULAR_MAX) {
        btw->ncircular++;
    } else if (btw->ncircular == LOGEVENT_CIRCULAR_MAX) {
        btw->circular_first =
            (btw->circular_first + 1) % LOGEVENT_CIRCULAR_MAX;
        sfree(btw->events_circular[btw->circular_first]);
        btw->events_circular[btw->circular_first] = dupstr("..");
    }

    if (btw->eventlog_callback)
        btw->eventlog_callback(btw->eventlog_ctx);
}

static void bridge_on_eventlog(void *ctx, const char *event)
{
    bridge_eventlog_append((PuttyBridgeTermWin *)ctx, event);
}

static void bridge_on_remote_exit(void *ctx, int exitcode, bool close_window)
{
    PuttyBridgeTermWin *btw = (PuttyBridgeTermWin *)ctx;

    if (btw->remote_exit_callback)
        btw->remote_exit_callback(
            btw->remote_exit_ctx, exitcode, close_window);
}

static void bridge_install_seat_callbacks(PuttyBridgeTermWin *btw)
{
    static const MacGuiSeatCallbacks seat_callbacks = {
        .on_update_specials_menu = bridge_on_update_specials_menu,
        .on_eventlog = bridge_on_eventlog,
        .on_remote_exit = bridge_on_remote_exit,
    };

    if (!btw || !btw->seat)
        return;
    mac_gui_seat_set_callbacks(btw->seat, &seat_callbacks, btw);
}

static bool putty_bridge_termwin_open_internal(
    PuttyBridgeTermWin *btw, const PuttyConf *pc, bool connect)
{
    static const char offline_banner[] =
        "PuTTY for macOS — TerminalView\r\n\r\n";
    Conf *conf_copy = NULL;
    bool launchable;
    bool ok;

    PUTTY_BRIDGE_ASSERT_MAIN_THREAD();
    if (!btw)
        return false;
    if (btw->session_initialised || btw->demo_initialised)
        return false;

    if (btw->mtw) {
        mac_termwin_free(btw->mtw);
        btw->mtw = NULL;
    }

    if (pc && pc->conf)
        conf_copy = putty_bridge_conf_copy(pc);

    btw->seat = mac_gui_seat_new(conf_copy);
    if (conf_copy)
        conf_free(conf_copy);
    if (!btw->seat)
        return false;

    btw->mtw = mac_gui_seat_get_termwin(btw->seat);
    btw->term = mac_gui_seat_get_terminal(btw->seat);
    btw->conf = mac_gui_seat_get_conf(btw->seat);
    bridge_install_termwin_callbacks(btw);
    bridge_install_seat_callbacks(btw);

    launchable = conf_launchable(btw->conf) ||
                 (cmdline_tooltype & TOOLTYPE_NONNETWORK) != 0;
    if (connect && launchable)
        ok = mac_gui_seat_start(btw->seat);
    else
        ok = mac_gui_seat_start_local_echo(btw->seat);

    if (!ok) {
        mac_gui_seat_free(btw->seat);
        btw->seat = NULL;
        btw->mtw = NULL;
        btw->term = NULL;
        btw->conf = NULL;
        return false;
    }

    btw->demo_ldisc = mac_gui_seat_get_ldisc(btw->seat);
    putty_bridge_termwin_setup_clipboards(btw);

    if (!connect || !launchable) {
        seat_output(
            mac_gui_seat_get_seat(btw->seat), SEAT_OUTPUT_STDOUT,
            offline_banner, sizeof(offline_banner) - 1);
    }

    btw->session_initialised = true;
    return true;
}

bool putty_bridge_termwin_open(
    PuttyBridgeTermWin *btw, const PuttyConf *conf, bool connect)
{
    return putty_bridge_termwin_open_internal(btw, conf, connect);
}

bool putty_bridge_termwin_session_is_active(const PuttyBridgeTermWin *btw)
{
    if (!btw || !btw->seat)
        return false;
    return mac_gui_seat_is_active(btw->seat);
}

bool putty_bridge_termwin_should_warn_on_close(const PuttyBridgeTermWin *btw)
{
    if (!btw || !btw->seat)
        return false;
    return mac_gui_seat_should_warn_on_close(btw->seat);
}

char *putty_bridge_termwin_close_warn_text(const PuttyBridgeTermWin *btw)
{
    if (!btw || !btw->seat)
        return NULL;
    return mac_gui_seat_close_warn_text(btw->seat);
}

void putty_bridge_termwin_free_close_warn_text(char *text)
{
    sfree(text);
}

void putty_bridge_termwin_set_specials_menu_callback(
    PuttyBridgeTermWin *btw,
    PuttyBridgeSpecialsMenuCallback callback,
    void *ctx)
{
    PUTTY_BRIDGE_ASSERT_MAIN_THREAD();
    if (!btw)
        return;
    btw->specials_menu_callback = callback;
    btw->specials_menu_ctx = ctx;
}

void putty_bridge_termwin_set_eventlog_callback(
    PuttyBridgeTermWin *btw,
    PuttyBridgeEventLogCallback callback,
    void *ctx)
{
    PUTTY_BRIDGE_ASSERT_MAIN_THREAD();
    if (!btw)
        return;
    btw->eventlog_callback = callback;
    btw->eventlog_ctx = ctx;
}

void putty_bridge_termwin_set_remote_exit_callback(
    PuttyBridgeTermWin *btw,
    PuttyBridgeRemoteExitCallback callback,
    void *ctx)
{
    PUTTY_BRIDGE_ASSERT_MAIN_THREAD();
    if (!btw)
        return;
    btw->remote_exit_callback = callback;
    btw->remote_exit_ctx = ctx;
}

bool putty_bridge_termwin_can_restart(const PuttyBridgeTermWin *btw)
{
    PUTTY_BRIDGE_ASSERT_MAIN_THREAD();
    if (!btw || !btw->seat)
        return false;
    return mac_gui_seat_can_restart(btw->seat);
}

bool putty_bridge_termwin_restart_session(PuttyBridgeTermWin *btw)
{
    PUTTY_BRIDGE_ASSERT_MAIN_THREAD();
    if (!btw || !btw->seat)
        return false;
    if (!mac_gui_seat_restart(btw->seat))
        return false;
    btw->demo_ldisc = mac_gui_seat_get_ldisc(btw->seat);
    btw->conf = mac_gui_seat_get_conf(btw->seat);
    seat_update_specials_menu(mac_gui_seat_get_seat(btw->seat));
    return true;
}

size_t putty_bridge_termwin_eventlog_count(const PuttyBridgeTermWin *btw)
{
    if (!btw)
        return 0;
    return (size_t)btw->ninitial + (size_t)btw->ncircular;
}

bool putty_bridge_termwin_eventlog_line(
    const PuttyBridgeTermWin *btw, size_t index, char *buf, size_t buflen)
{
    const char *line = NULL;
    size_t len;

    if (!btw || !buf || buflen == 0)
        return false;
    if (index < (size_t)btw->ninitial) {
        line = btw->events_initial[index];
    } else {
        size_t circ = index - (size_t)btw->ninitial;
        if (circ >= (size_t)btw->ncircular)
            return false;
        line = btw->events_circular[
            (btw->circular_first + (int)circ) % LOGEVENT_CIRCULAR_MAX];
    }
    if (!line)
        return false;

    len = strlen(line);
    if (len >= buflen)
        len = buflen - 1;
    memcpy(buf, line, len);
    buf[len] = '\0';
    return true;
}

void putty_bridge_termwin_eventlog_append_test(
    PuttyBridgeTermWin *btw, const char *message)
{
    PUTTY_BRIDGE_ASSERT_MAIN_THREAD();
    bridge_eventlog_append(btw, message ? message : "");
}

bool putty_bridge_termwin_has_specials(const PuttyBridgeTermWin *btw)
{
    const SessionSpecial *specials;
    Backend *backend;

    PUTTY_BRIDGE_ASSERT_MAIN_THREAD();
    if (!btw || !btw->seat)
        return false;
    backend = mac_gui_seat_get_backend(btw->seat);
    if (!backend)
        return false;
    specials = backend_get_specials(backend);
    return specials != NULL;
}

size_t putty_bridge_termwin_copy_specials(
    const PuttyBridgeTermWin *btw,
    PuttyBridgeSessionSpecial *out,
    size_t max_out)
{
    const SessionSpecial *specials;
    Backend *backend;
    size_t i = 0;
    int nesting = 1;

    PUTTY_BRIDGE_ASSERT_MAIN_THREAD();
    if (!btw || !btw->seat || !out || max_out == 0)
        return 0;

    backend = mac_gui_seat_get_backend(btw->seat);
    if (!backend)
        return 0;
    specials = backend_get_specials(backend);
    if (!specials)
        return 0;

    while (nesting > 0 && i < max_out) {
        out[i].name = specials[i].name;
        out[i].code = (int32_t)specials[i].code;
        out[i].arg = specials[i].arg;
        switch (specials[i].code) {
          case SS_SUBMENU:
            nesting++;
            break;
          case SS_EXITMENU:
            nesting--;
            break;
          default:
            break;
        }
        i++;
    }
    return i;
}

void putty_bridge_termwin_send_special(
    PuttyBridgeTermWin *btw, int32_t code, int32_t arg)
{
    Backend *backend;

    PUTTY_BRIDGE_ASSERT_MAIN_THREAD();
    if (!btw || !btw->seat)
        return;
    backend = mac_gui_seat_get_backend(btw->seat);
    if (!backend)
        return;
    backend_special(backend, (SessionSpecialCode)code, arg);
}

int32_t putty_bridge_special_code_sep(void)
{
    return (int32_t)SS_SEP;
}

int32_t putty_bridge_special_code_submenu(void)
{
    return (int32_t)SS_SUBMENU;
}

int32_t putty_bridge_special_code_exitmenu(void)
{
    return (int32_t)SS_EXITMENU;
}

bool putty_bridge_termwin_terminal_has_visible_text(const PuttyBridgeTermWin *btw)
{
    int y, x;

    PUTTY_BRIDGE_ASSERT_MAIN_THREAD();
    if (!btw || !btw->term)
        return false;

    for (y = 0; y < btw->term->rows; y++) {
        termline *tl = term_get_line(btw->term, y);
        if (!tl)
            continue;
        for (x = 0; x < tl->cols; x++) {
            if (tl->chars[x].chr != ' ' && tl->chars[x].chr != 0) {
                term_release_line(tl);
                return true;
            }
        }
        term_release_line(tl);
    }
    return false;
}

struct bridge_change_settings_ctx {
    PuttyBridgeTermWin *btw;
    Conf *working;
};

static void bridge_after_change_settings(void *vctx, int result)
{
    struct bridge_change_settings_ctx *ctx =
        (struct bridge_change_settings_ctx *)vctx;

    if (result > 0 && ctx->btw && ctx->btw->seat && ctx->working) {
        mac_gui_seat_reconfigure(ctx->btw->seat, ctx->working);
        ctx->btw->conf = mac_gui_seat_get_conf(ctx->btw->seat);
        if (ctx->btw->swift_callbacks.settings_changed)
            ctx->btw->swift_callbacks.settings_changed(ctx->btw->swift_view_ctx);
    }

    if (ctx->working)
        conf_free(ctx->working);
    sfree(ctx);
}

bool putty_bridge_termwin_change_settings(PuttyBridgeTermWin *btw)
{
    struct bridge_change_settings_ctx *ctx;
    char *title;
    int protcfginfo = 0;
    Backend *backend;

    PUTTY_BRIDGE_ASSERT_MAIN_THREAD();
    if (!btw || !btw->conf || !btw->seat)
        return false;

    ctx = snew(struct bridge_change_settings_ctx);
    ctx->btw = btw;
    ctx->working = conf_copy(btw->conf);
    if (!ctx->working) {
        sfree(ctx);
        return false;
    }

    if (btw->term)
        term_pre_reconfig(btw->term, ctx->working);

    backend = mac_gui_seat_get_backend(btw->seat);
    if (backend)
        protcfginfo = backend_cfg_info(backend);

    title = dupcat(appname, " Reconfiguration");
    mac_config_create_box(title, ctx->working, true, protcfginfo,
                          bridge_after_change_settings, ctx);
    sfree(title);
    return true;
}

void putty_bridge_launch_duplicate_session(PuttyBridgeTermWin *btw)
{
    Conf *conf;

    PUTTY_BRIDGE_ASSERT_MAIN_THREAD();
    if (!btw || !btw->seat)
        return;
    conf = mac_gui_seat_get_conf(btw->seat);
    if (!conf)
        return;
    if (dup_check_launchable && !conf_launchable(conf))
        return;
    launch_duplicate_session(conf);
}

bool putty_bridge_termwin_init_demo(PuttyBridgeTermWin *btw)
{
    static const char banner[] =
        "PuTTY for macOS — TerminalView (Phase 4.2)\r\n\r\n";

    PUTTY_BRIDGE_ASSERT_MAIN_THREAD();
    if (btw->session_initialised)
        return false;
    if (btw->demo_initialised)
        return true;

    if (!btw->mtw) {
        btw->mtw = mac_termwin_new();
        bridge_install_termwin_callbacks(btw);
    }

    btw->conf = conf_new();
    do_defaults(NULL, btw->conf);
    init_ucs_generic(btw->conf, &btw->ucsdata);

    mac_termwin_set_conf(btw->mtw, btw->conf);
    btw->term = term_init(btw->conf, &btw->ucsdata, mac_termwin_get_termwin(btw->mtw));
    if (!btw->term)
        return false;

    mac_termwin_set_terminal(btw->mtw, btw->term);
    term_size(btw->term, 24, 80, conf_get_int(btw->conf, CONF_savelines));
    putty_bridge_termwin_setup_clipboards(btw);

    conf_set_int(btw->conf, CONF_localecho, FORCE_ON);
    conf_set_int(btw->conf, CONF_localedit, FORCE_OFF);
    btw->demo_seat.vt = &bridge_demo_seat_vt;
    btw->demo_backend.vt = &null_backend;
    btw->demo_ldisc = ldisc_create(
        btw->conf, btw->term, &btw->demo_backend, &btw->demo_seat);
    if (!btw->demo_ldisc)
        return false;
    ldisc_echoedit_update(btw->demo_ldisc);

    term_data(btw->term, banner, sizeof(banner) - 1);
    term_update(btw->term);

    btw->demo_initialised = true;
    return true;
}

void putty_bridge_termwin_set_backing_scale(PuttyBridgeTermWin *btw, double scale)
{
    PUTTY_BRIDGE_ASSERT_MAIN_THREAD();
    if (!btw || !btw->mtw)
        return;
    mac_termwin_set_backing_scale(btw->mtw, scale);
}

double putty_bridge_termwin_get_backing_scale(const PuttyBridgeTermWin *btw)
{
    PUTTY_BRIDGE_ASSERT_MAIN_THREAD();
    if (!btw || !btw->mtw)
        return 1.0;
    return mac_termwin_get_backing_scale(btw->mtw);
}

const char *putty_bridge_termwin_font_spec(const PuttyBridgeTermWin *btw)
{
    FontSpec *fs;

    if (!btw || !btw->conf)
        return DEFAULT_MAC_FONT;
    fs = conf_get_fontspec(btw->conf, CONF_font);
    if (fs && fs->name && *fs->name)
        return fs->name;
    return DEFAULT_MAC_FONT;
}

void putty_bridge_termwin_set_font_metrics(
    PuttyBridgeTermWin *btw, double cell_width_pt, double cell_height_pt,
    double ascent_pt, double descent_pt)
{
    PUTTY_BRIDGE_ASSERT_MAIN_THREAD();
    if (!btw || !btw->mtw)
        return;
    mac_termwin_set_font_metrics(
        btw->mtw, cell_width_pt, cell_height_pt, ascent_pt, descent_pt);
}

double putty_bridge_termwin_cell_width_pt(const PuttyBridgeTermWin *btw)
{
    if (!btw || !btw->mtw)
        return 0.0;
    return btw->mtw->cell_width_pt;
}

double putty_bridge_termwin_cell_height_pt(const PuttyBridgeTermWin *btw)
{
    if (!btw || !btw->mtw)
        return 0.0;
    return btw->mtw->cell_height_pt;
}

void putty_bridge_termwin_resize_to_view(
    PuttyBridgeTermWin *btw, double view_width_pt, double view_height_pt)
{
    int cols, rows;

    PUTTY_BRIDGE_ASSERT_MAIN_THREAD();
    if (!btw || !btw->term || !btw->mtw)
        return;
    if (btw->mtw->cell_width_pt <= 0.0 || btw->mtw->cell_height_pt <= 0.0)
        return;

    cols = (int)(view_width_pt / btw->mtw->cell_width_pt);
    rows = (int)(view_height_pt / btw->mtw->cell_height_pt);
    if (cols < 1)
        cols = 1;
    if (rows < 1)
        rows = 1;

    if (btw->term->cols != cols || btw->term->rows != rows)
        term_size(btw->term, rows, cols, conf_get_int(btw->conf, CONF_savelines));
}

void putty_bridge_termwin_paint(
    PuttyBridgeTermWin *btw, int32_t left, int32_t top,
    int32_t right, int32_t bottom)
{
    TermWin *tw;

    PUTTY_BRIDGE_ASSERT_MAIN_THREAD();
    if (!btw || !btw->term || !btw->mtw)
        return;

    /*
     * term_paint → do_paint emits win_draw_text without calling
     * setup_draw_ctx. Windows sets an HDC before term_paint; we must
     * bracket with setup/free so Swift beginPaint/endPaint flush glyphs
     * into the current NSGraphicsContext (i.e. inside TerminalView.draw).
     */
    tw = mac_termwin_get_termwin(btw->mtw);
    if (!win_setup_draw_ctx(tw))
        return;
    term_paint(btw->term, left, top, right, bottom, true);
    win_free_draw_ctx(tw);
}

bool putty_bridge_termwin_palette_colour(
    const PuttyBridgeTermWin *btw, uint32_t index,
    uint8_t *r, uint8_t *g, uint8_t *b)
{
    const rgb *colours;

    PUTTY_BRIDGE_ASSERT_MAIN_THREAD();
    if (index >= OSC4_NCOLOURS)
        return false;

    colours = mac_termwin_get_colours(btw->mtw);
    *r = colours[index].r;
    *g = colours[index].g;
    *b = colours[index].b;
    return true;
}

int32_t putty_bridge_termwin_cols(const PuttyBridgeTermWin *btw)
{
    if (!btw->term)
        return 0;
    return btw->term->cols;
}

int32_t putty_bridge_termwin_rows(const PuttyBridgeTermWin *btw)
{
    if (!btw->term)
        return 0;
    return btw->term->rows;
}

double putty_bridge_termwin_ascent_pt(const PuttyBridgeTermWin *btw)
{
    PUTTY_BRIDGE_ASSERT_MAIN_THREAD();
    if (!btw || !btw->mtw)
        return 0.0;
    return btw->mtw->ascent_pt;
}

int32_t putty_bridge_termwin_cursor_type(const PuttyBridgeTermWin *btw)
{
    PUTTY_BRIDGE_ASSERT_MAIN_THREAD();
    if (!btw || !btw->mtw)
        return 0;
    return btw->mtw->cursor_type;
}

int32_t putty_bridge_termwin_bold_style(const PuttyBridgeTermWin *btw)
{
    PUTTY_BRIDGE_ASSERT_MAIN_THREAD();
    if (!btw || !btw->mtw)
        return 0;
    return btw->mtw->bold_style;
}

bool putty_bridge_termwin_resize_grid(
    PuttyBridgeTermWin *btw, int32_t cols, int32_t rows)
{
    PUTTY_BRIDGE_ASSERT_MAIN_THREAD();
    if (!btw->term || cols < 1 || rows < 1)
        return false;

    term_size(btw->term, rows, cols, conf_get_int(btw->conf, CONF_savelines));
    return true;
}

size_t putty_bridge_termwin_feed(
    PuttyBridgeTermWin *btw, const void *data, size_t len)
{
    PUTTY_BRIDGE_ASSERT_MAIN_THREAD();
    if (!data || len == 0)
        return 0;

    if (btw->seat) {
        return seat_output(
            mac_gui_seat_get_seat(btw->seat), SEAT_OUTPUT_STDOUT, data, len);
    }

    if (!btw->term)
        return 0;

    term_data(btw->term, data, len);
    term_update(btw->term);
    return len;
}

bool putty_bridge_termwin_compute_dirty_rect(
    PuttyBridgeTermWin *btw, PuttyBridgeTermWinRect *out)
{
    MacTermWinRect dirty;

    PUTTY_BRIDGE_ASSERT_MAIN_THREAD();
    if (!out || !mac_termwin_compute_dirty_rect(btw->mtw, &dirty))
        return false;

    out->x = dirty.x;
    out->y = dirty.y;
    out->width = dirty.width;
    out->height = dirty.height;
    return true;
}

int putty_bridge_termwin_perf_paint_benchmark(
    PuttyBridgeTermWin *btw, int frames, double budget_ms)
{
    Terminal *term;
    uint64_t start, end, total;
    double mean_ms;
    int cols, rows;
    const char line[] =
        "abcdefghijklmnopqrstuvwxyz0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ\r\n";
    int i;

    if (getenv("PUTTY_BRIDGE_PERF_SKIP"))
        return 0;

    PUTTY_BRIDGE_ASSERT_MAIN_THREAD();
    if (!btw->term || frames < 1 || budget_ms <= 0.0)
        return 1;

    term = btw->term;
    cols = term->cols;
    rows = term->rows;

    for (i = 0; i < rows; i++)
        term_data(term, line, sizeof(line) - 1);
    term_update(term);

    start = GETTICKCOUNT();
    for (i = 0; i < frames; i++)
        term_paint(term, 0, 0, cols - 1, rows - 1, true);
    end = GETTICKCOUNT();

    total = end - start;
    mean_ms = (double)total / (double)frames;
    if (mean_ms >= budget_ms)
        return (int)(mean_ms + 0.5);

    return 0;
}

void putty_bridge_termwin_key_bytes(
    PuttyBridgeTermWin *btw, int32_t codepage, const void *data, int32_t len)
{
    PUTTY_BRIDGE_ASSERT_MAIN_THREAD();
    if (!btw->term || !data || len <= 0)
        return;

    term_keyinput(btw->term, codepage, data, len);
}

void putty_bridge_termwin_key_special(
    PuttyBridgeTermWin *btw, const char *nul_terminated)
{
    PUTTY_BRIDGE_ASSERT_MAIN_THREAD();
    if (!btw->term || !nul_terminated)
        return;

    term_keyinput(btw->term, -1, nul_terminated, -2);
}

void putty_bridge_termwin_key_wide(
    PuttyBridgeTermWin *btw, const wchar_t *data, int32_t len)
{
    PUTTY_BRIDGE_ASSERT_MAIN_THREAD();
    if (!btw->term || !data || len <= 0)
        return;

    term_keyinputw(btw->term, data, len);
}

int32_t putty_bridge_termwin_format_return(
    PuttyBridgeTermWin *btw, char *buf, int32_t buflen, bool *special_out)
{
    PUTTY_BRIDGE_ASSERT_MAIN_THREAD();
    if (!btw->term || !buf || buflen <= 0 || !special_out)
        return 0;

    return (int32_t)osxkeys_format_return(
        btw->term, buf, (size_t)buflen, special_out);
}

int32_t putty_bridge_termwin_format_arrow(
    PuttyBridgeTermWin *btw, int32_t xkey, bool shift, bool ctrl, bool alt,
    char *buf, int32_t buflen, bool *consumed_alt_out)
{
    PUTTY_BRIDGE_ASSERT_MAIN_THREAD();
    if (!btw->term || !buf || buflen <= 0)
        return 0;

    return (int32_t)osxkeys_format_arrow(
        btw->term, xkey, shift, ctrl, alt, buf, (size_t)buflen,
        consumed_alt_out);
}

int32_t putty_bridge_termwin_format_function(
    PuttyBridgeTermWin *btw, int32_t fkey_number, bool shift, bool ctrl,
    bool alt, char *buf, int32_t buflen, bool *consumed_alt_out)
{
    PUTTY_BRIDGE_ASSERT_MAIN_THREAD();
    if (!btw->term || !buf || buflen <= 0 || fkey_number < 1)
        return 0;

    return (int32_t)osxkeys_format_function(
        btw->term, fkey_number, shift, ctrl, alt, buf, (size_t)buflen,
        consumed_alt_out);
}

int32_t putty_bridge_termwin_format_small_keypad(
    PuttyBridgeTermWin *btw, int32_t key, bool shift, bool ctrl, bool alt,
    char *buf, int32_t buflen, bool *consumed_alt_out)
{
    PUTTY_BRIDGE_ASSERT_MAIN_THREAD();
    if (!btw->term || !buf || buflen <= 0)
        return 0;

    return (int32_t)osxkeys_format_small_keypad(
        btw->term, (SmallKeypadKey)key, shift, ctrl, alt, buf, (size_t)buflen,
        consumed_alt_out);
}

int32_t putty_bridge_termwin_format_backspace(
    PuttyBridgeTermWin *btw, bool shift, char *buf, int32_t buflen,
    bool *special_out)
{
    PUTTY_BRIDGE_ASSERT_MAIN_THREAD();
    if (!btw->term || !buf || buflen <= 0 || !special_out)
        return 0;

    return (int32_t)osxkeys_format_backspace(
        btw->term, shift, buf, (size_t)buflen, special_out);
}

uint8_t putty_bridge_termwin_apply_ctrl(uint8_t c)
{
    return osxkeys_apply_ctrl(c);
}

void putty_bridge_termwin_mouse(
    PuttyBridgeTermWin *btw, int32_t button_raw, int32_t action,
    int32_t cell_x, int32_t cell_y, bool shift, bool ctrl, bool alt)
{
    Mouse_Button braw, bcooked;
    Mouse_Action ma;

    PUTTY_BRIDGE_ASSERT_MAIN_THREAD();
    if (!btw->term)
        return;

    braw = (Mouse_Button)button_raw;
    bcooked = bridge_translate_button(btw, braw);
    ma = (Mouse_Action)action;

    term_mouse(btw->term, braw, bcooked, ma, cell_x, cell_y, shift, ctrl, alt);
    /*
     * term_mouse schedules term_update via a toplevel callback. Flush it
     * now so mac_tw_setup_draw_ctx can request a deferred AppKit redraw
     * before the next mouse-drag event (keeps selection highlight live).
     */
    while (run_toplevel_callbacks())
        ;
}

void putty_bridge_termwin_scroll_lines(PuttyBridgeTermWin *btw, int32_t lines)
{
    PUTTY_BRIDGE_ASSERT_MAIN_THREAD();
    if (!btw->term || lines == 0)
        return;

    term_scroll(btw->term, 0, lines);
}

void putty_bridge_termwin_scroll_to(PuttyBridgeTermWin *btw, int32_t position)
{
    PUTTY_BRIDGE_ASSERT_MAIN_THREAD();
    if (!btw->term)
        return;

    term_scroll(btw->term, 1, position);
}

void putty_bridge_termwin_request_resize_completed(PuttyBridgeTermWin *btw)
{
    PUTTY_BRIDGE_ASSERT_MAIN_THREAD();
    if (!btw->term)
        return;

    term_resize_request_completed(btw->term);
}

int32_t putty_bridge_termwin_resize_action(const PuttyBridgeTermWin *btw)
{
    if (!btw->conf)
        return PUTTY_BRIDGE_RESIZE_TERM;
    return conf_get_int(btw->conf, CONF_resize_action);
}

bool putty_bridge_termwin_scrollbar_enabled(const PuttyBridgeTermWin *btw)
{
    if (!btw->conf)
        return true;
    return conf_get_bool(btw->conf, CONF_scrollbar);
}

void putty_bridge_termwin_view_size_for_grid(
    const PuttyBridgeTermWin *btw, int32_t cols, int32_t rows,
    double *width_pt, double *height_pt)
{
    if (width_pt)
        *width_pt = btw->mtw->cell_width_pt * cols;
    if (height_pt)
        *height_pt = btw->mtw->cell_height_pt * rows;
}

void putty_bridge_termwin_apply_live_resize(
    PuttyBridgeTermWin *btw, double view_width_pt, double view_height_pt)
{
    int action;

    PUTTY_BRIDGE_ASSERT_MAIN_THREAD();
    if (!btw->term)
        return;

    action = conf_get_int(btw->conf, CONF_resize_action);
    if (action == RESIZE_DISABLED || action == RESIZE_FONT)
        return;

    putty_bridge_termwin_resize_to_view(btw, view_width_pt, view_height_pt);
}

void putty_bridge_termwin_scrollbar_state(
    const PuttyBridgeTermWin *btw,
    int32_t *total, int32_t *start, int32_t *page)
{
    if (total)
        *total = btw->mtw->scroll_total;
    if (start)
        *start = btw->mtw->scroll_start;
    if (page)
        *page = btw->mtw->scroll_page;
}

bool putty_bridge_termwin_win_name_always(const PuttyBridgeTermWin *btw)
{
    if (!btw->conf)
        return false;
    return conf_get_bool(btw->conf, CONF_win_name_always);
}

bool putty_bridge_termwin_bell_wavefile_path(
    const PuttyBridgeTermWin *btw, char *buf, size_t buflen)
{
    const Filename *wavefile;

    if (!btw->conf || !buf || buflen == 0)
        return false;

    wavefile = conf_get_filename(btw->conf, CONF_bell_wavefile);
    if (filename_is_null(wavefile))
        return false;

    strncpy(buf, filename_to_str(wavefile), buflen - 1);
    buf[buflen - 1] = '\0';
    return buf[0] != '\0';
}

bool putty_bridge_termwin_raw_mouse_active(const PuttyBridgeTermWin *btw)
{
    Terminal *term;

    if (!btw->term)
        return false;

    term = btw->term;
    return term->xterm_mouse != 0 && !term->xterm_mouse_forbidden;
}

bool putty_bridge_termwin_pointer_indicates_raw_mouse(
    const PuttyBridgeTermWin *btw)
{
    PUTTY_BRIDGE_ASSERT_MAIN_THREAD();
    return btw->mtw->pointer_indicates_raw_mouse;
}

bool putty_bridge_termwin_mouse_override_shift(const PuttyBridgeTermWin *btw)
{
    if (!btw->conf)
        return true;
    return conf_get_bool(btw->conf, CONF_mouse_override);
}

int32_t putty_bridge_termwin_mouse_buttons_mode(const PuttyBridgeTermWin *btw)
{
    PUTTY_BRIDGE_ASSERT_MAIN_THREAD();
    if (!btw || !btw->conf)
        return PUTTY_BRIDGE_MOUSE_COMPROMISE;
    return conf_get_int(btw->conf, CONF_mouse_is_xterm);
}

bool putty_bridge_termwin_right_click_shows_menu(
    const PuttyBridgeTermWin *btw, bool control)
{
    /*
     * Match Windows: MOUSE_WINDOWS always shows the context menu on
     * right-click; Control+right-click shows it in any mode (escape hatch
     * when right-click is bound to paste/extend).
     */
    if (control)
        return true;
    return putty_bridge_termwin_mouse_buttons_mode(btw) ==
           PUTTY_BRIDGE_MOUSE_WINDOWS;
}

void putty_bridge_termwin_cancel_selection_drag(PuttyBridgeTermWin *btw)
{
    PUTTY_BRIDGE_ASSERT_MAIN_THREAD();
    if (!btw || !btw->term)
        return;
    term_cancel_selection_drag(btw->term);
}

void putty_bridge_termwin_copy_selection(PuttyBridgeTermWin *btw)
{
    static const int clips[] = { CLIP_CLIPBOARD };

    PUTTY_BRIDGE_ASSERT_MAIN_THREAD();
    if (!btw->term)
        return;

    term_request_copy(btw->term, clips, lenof(clips));
}

void putty_bridge_termwin_copy_all(PuttyBridgeTermWin *btw)
{
    static const int clips[] = { COPYALL_CLIPBOARDS };

    PUTTY_BRIDGE_ASSERT_MAIN_THREAD();
    if (!btw->term)
        return;

    term_copyall(btw->term, clips, lenof(clips));
}

void putty_bridge_termwin_select_all(PuttyBridgeTermWin *btw)
{
    Terminal *term;

    PUTTY_BRIDGE_ASSERT_MAIN_THREAD();
    if (!btw->term)
        return;

    term = btw->term;
    term->seltype = LEXICOGRAPHIC;
    term->selstate = SELECTED;
    term->selstart.x = 0;
    term->selstart.y = term->disptop;
    term->selend.x = term->cols > 0 ? term->cols - 1 : 0;
    term->selend.y = term->disptop + term->rows - 1;
    incpos_fn(&term->selend, term->cols);
    term_invalidate(term);
}

void putty_bridge_termwin_request_paste(
    PuttyBridgeTermWin *btw, int32_t clipboard)
{
    PUTTY_BRIDGE_ASSERT_MAIN_THREAD();
    if (!btw->term)
        return;

    term_request_paste(btw->term, clipboard);
}

void putty_bridge_termwin_paste_text(
    PuttyBridgeTermWin *btw, const wchar_t *data, int32_t len)
{
    PUTTY_BRIDGE_ASSERT_MAIN_THREAD();
    if (!btw->term || !data || len <= 0)
        return;

    term_do_paste(btw->term, data, len);
}

void putty_bridge_termwin_setup_clipboards(PuttyBridgeTermWin *btw)
{
    Terminal *term;
    Conf *conf;

    PUTTY_BRIDGE_ASSERT_MAIN_THREAD();
    if (!btw->term || !btw->conf)
        return;

    term = btw->term;
    conf = btw->conf;

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

void putty_bridge_termwin_lost_clipboard_ownership(
    PuttyBridgeTermWin *btw, int32_t clipboard)
{
    PUTTY_BRIDGE_ASSERT_MAIN_THREAD();
    if (!btw->term)
        return;

    term_lost_clipboard_ownership(btw->term, clipboard);
}

bool putty_bridge_termwin_mouse_autocopy_enabled(const PuttyBridgeTermWin *btw)
{
    if (!btw->conf)
        return false;
    return conf_get_bool(btw->conf, CONF_mouseautocopy);
}

int32_t putty_bridge_termwin_mouse_select_clipboard_count(
    const PuttyBridgeTermWin *btw)
{
    if (!btw->term)
        return 0;
    return btw->term->n_mouse_select_clipboards;
}

int putty_bridge_termwin_clipboard_smoke(void)
{
    PuttyBridgeTermWin *btw;

    btw = putty_bridge_termwin_new();
    if (!putty_bridge_termwin_init_demo(btw)) {
        putty_bridge_termwin_free(btw);
        return 1;
    }

    /* HIG default: no implicit copy-on-select to system clipboard. */
    if (putty_bridge_termwin_mouse_autocopy_enabled(btw)) {
        putty_bridge_termwin_free(btw);
        return 2;
    }
    if (putty_bridge_termwin_mouse_select_clipboard_count(btw) != 2) {
        putty_bridge_termwin_free(btw);
        return 3;
    }
    if (btw->term->mouse_select_clipboards[0] != CLIP_LOCAL) {
        putty_bridge_termwin_free(btw);
        return 4;
    }
    {
        int i;
        for (i = 0; i < btw->term->n_mouse_select_clipboards; i++) {
            if (btw->term->mouse_select_clipboards[i] == CLIP_CLIPBOARD) {
                putty_bridge_termwin_free(btw);
                return 5;
            }
        }
    }

    conf_set_bool(btw->conf, CONF_mouseautocopy, true);
    putty_bridge_termwin_setup_clipboards(btw);
    if (putty_bridge_termwin_mouse_select_clipboard_count(btw) != 3) {
        putty_bridge_termwin_free(btw);
        return 6;
    }
    if (btw->term->mouse_select_clipboards[2] != CLIP_CLIPBOARD) {
        putty_bridge_termwin_free(btw);
        return 7;
    }

    putty_bridge_termwin_free(btw);
    return 0;
}

int putty_bridge_termwin_input_smoke(void)
{
    PuttyBridgeTermWin *btw;
    char buf[32];
    bool special = false;
    int len;

    btw = putty_bridge_termwin_new();
    if (!putty_bridge_termwin_init_demo(btw)) {
        putty_bridge_termwin_free(btw);
        return 1;
    }

    putty_bridge_termwin_key_bytes(btw, -1, "a", 1);
    len = putty_bridge_termwin_format_return(btw, buf, sizeof(buf), &special);
    if (len <= 0) {
        putty_bridge_termwin_free(btw);
        return 2;
    }
    if (special)
        putty_bridge_termwin_key_special(btw, buf);
    else
        putty_bridge_termwin_key_bytes(btw, -1, buf, len);

    putty_bridge_termwin_mouse(
        btw, MBT_LEFT, MA_CLICK, 1, 1, false, false, false);
    putty_bridge_termwin_mouse(
        btw, MBT_LEFT, MA_DRAG, 5, 1, false, false, false);
    putty_bridge_termwin_mouse(
        btw, MBT_LEFT, MA_RELEASE, 5, 1, false, false, false);

    /*
     * Default CONF_mouse_is_xterm is MOUSE_COMPROMISE: right-click pastes.
     * Exercise the cooked mapping (does not require a real pasteboard).
     */
    if (putty_bridge_termwin_mouse_buttons_mode(btw) !=
        PUTTY_BRIDGE_MOUSE_COMPROMISE) {
        putty_bridge_termwin_free(btw);
        return 3;
    }
    if (putty_bridge_termwin_right_click_shows_menu(btw, false)) {
        putty_bridge_termwin_free(btw);
        return 4;
    }
    if (!putty_bridge_termwin_right_click_shows_menu(btw, true)) {
        putty_bridge_termwin_free(btw);
        return 5;
    }
    putty_bridge_termwin_mouse(
        btw, MBT_RIGHT, MA_CLICK, 2, 2, false, false, false);
    putty_bridge_termwin_mouse(
        btw, MBT_RIGHT, MA_RELEASE, 2, 2, false, false, false);

    conf_set_int(btw->conf, CONF_mouse_is_xterm, MOUSE_WINDOWS);
    if (!putty_bridge_termwin_right_click_shows_menu(btw, false)) {
        putty_bridge_termwin_free(btw);
        return 6;
    }

    putty_bridge_termwin_select_all(btw);
    putty_bridge_termwin_free(btw);
    return 0;
}

static int32_t smoke_scroll_total, smoke_scroll_start, smoke_scroll_page;
static int smoke_req_cols, smoke_req_rows;

static void smoke_set_scrollbar(
    void *ctx, int32_t total, int32_t start, int32_t page)
{
    (void)ctx;
    smoke_scroll_total = total;
    smoke_scroll_start = start;
    smoke_scroll_page = page;
}

static void smoke_request_resize(void *ctx, int32_t cols, int32_t rows)
{
    (void)ctx;
    smoke_req_cols = cols;
    smoke_req_rows = rows;
}

static const PuttyBridgeTermWinCallbacks smoke_scroll_resize_cbs = {
    .set_scrollbar = smoke_set_scrollbar,
    .request_resize = smoke_request_resize,
};

int putty_bridge_termwin_scroll_resize_smoke(void)
{
    PuttyBridgeTermWin *btw;
    int32_t total, start, page, rows;
    double width_pt, height_pt;

    btw = putty_bridge_termwin_new();
    putty_bridge_termwin_set_callbacks(btw, &smoke_scroll_resize_cbs, NULL);
    if (!putty_bridge_termwin_init_demo(btw)) {
        putty_bridge_termwin_free(btw);
        return 1;
    }

    if (putty_bridge_termwin_resize_action(btw) != PUTTY_BRIDGE_RESIZE_TERM) {
        putty_bridge_termwin_free(btw);
        return 2;
    }
    if (!putty_bridge_termwin_scrollbar_enabled(btw)) {
        putty_bridge_termwin_free(btw);
        return 3;
    }

    putty_bridge_termwin_set_font_metrics(btw, 10.0, 20.0, 15.0, 5.0);
    putty_bridge_termwin_view_size_for_grid(btw, 80, 24, &width_pt, &height_pt);
    if (width_pt != 800.0 || height_pt != 480.0) {
        putty_bridge_termwin_free(btw);
        return 4;
    }

    putty_bridge_termwin_apply_live_resize(btw, 400.0, 200.0);
    if (putty_bridge_termwin_cols(btw) != 40 ||
        putty_bridge_termwin_rows(btw) != 10) {
        putty_bridge_termwin_free(btw);
        return 5;
    }

    putty_bridge_termwin_resize_grid(btw, 80, 24);
    conf_set_int(btw->conf, CONF_resize_action, RESIZE_DISABLED);
    putty_bridge_termwin_apply_live_resize(btw, 1600.0, 960.0);
    if (putty_bridge_termwin_cols(btw) != 80 ||
        putty_bridge_termwin_rows(btw) != 24) {
        putty_bridge_termwin_free(btw);
        return 6;
    }

    conf_set_int(btw->conf, CONF_resize_action, RESIZE_TERM);
    for (int i = 0; i < 50; i++)
        putty_bridge_termwin_feed(btw, "scrollback line\r\n", 17);

    putty_bridge_termwin_scrollbar_state(btw, &total, &start, &page);
    rows = putty_bridge_termwin_rows(btw);
    if (total <= rows || page != rows) {
        putty_bridge_termwin_free(btw);
        return 7;
    }

    putty_bridge_termwin_scroll_to(btw, 10);
    putty_bridge_termwin_scrollbar_state(btw, &total, &start, &page);

    smoke_req_cols = smoke_req_rows = 0;
    win_request_resize(mac_termwin_get_termwin(btw->mtw), 90, 28);
    if (smoke_req_cols != 90 || smoke_req_rows != 28) {
        putty_bridge_termwin_free(btw);
        return 8;
    }

    putty_bridge_termwin_free(btw);
    return 0;
}

static int32_t smoke_bell_mode;
static char smoke_window_title[256];
static char smoke_icon_title[256];

static void smoke_bell(void *ctx, int32_t mode)
{
    (void)ctx;
    smoke_bell_mode = mode;
}

static void smoke_set_title(void *ctx, const char *title_utf8)
{
    (void)ctx;
    strncpy(smoke_window_title, title_utf8 ? title_utf8 : "",
            sizeof(smoke_window_title) - 1);
    smoke_window_title[sizeof(smoke_window_title) - 1] = '\0';
}

static void smoke_set_icon_title(void *ctx, const char *title_utf8)
{
    (void)ctx;
    strncpy(smoke_icon_title, title_utf8 ? title_utf8 : "",
            sizeof(smoke_icon_title) - 1);
    smoke_icon_title[sizeof(smoke_icon_title) - 1] = '\0';
}

static const PuttyBridgeTermWinCallbacks smoke_bell_title_cbs = {
    .bell = smoke_bell,
    .set_title = smoke_set_title,
    .set_icon_title = smoke_set_icon_title,
};

int putty_bridge_termwin_bell_title_smoke(void)
{
    PuttyBridgeTermWin *btw;
    char wavepath[512];

    btw = putty_bridge_termwin_new();
    putty_bridge_termwin_set_callbacks(btw, &smoke_bell_title_cbs, NULL);
    if (!putty_bridge_termwin_init_demo(btw)) {
        putty_bridge_termwin_free(btw);
        return 1;
    }

    if (putty_bridge_termwin_win_name_always(btw) !=
        conf_get_bool(btw->conf, CONF_win_name_always)) {
        putty_bridge_termwin_free(btw);
        return 2;
    }

    smoke_bell_mode = -1;
    smoke_window_title[0] = smoke_icon_title[0] = '\0';

    win_bell(mac_termwin_get_termwin(btw->mtw), BELL_DEFAULT);
    if (smoke_bell_mode != PUTTY_BRIDGE_BELL_DEFAULT) {
        putty_bridge_termwin_free(btw);
        return 3;
    }

    win_set_title(mac_termwin_get_termwin(btw->mtw), "PuTTY Session", CP_UTF8);
    if (strcmp(smoke_window_title, "PuTTY Session") != 0) {
        putty_bridge_termwin_free(btw);
        return 4;
    }

    win_set_icon_title(mac_termwin_get_termwin(btw->mtw), "ssh.example", CP_UTF8);
    if (strcmp(smoke_icon_title, "ssh.example") != 0) {
        putty_bridge_termwin_free(btw);
        return 5;
    }

    putty_bridge_termwin_feed(btw, "\033]0;OSC Title\007", 14);
    if (strcmp(smoke_window_title, "OSC Title") != 0) {
        putty_bridge_termwin_free(btw);
        return 6;
    }

    if (putty_bridge_termwin_bell_wavefile_path(btw, wavepath, sizeof(wavepath))) {
        putty_bridge_termwin_free(btw);
        return 7;
    }

    conf_set_int(btw->conf, CONF_beep, BELL_WAVEFILE);
    conf_set_filename(btw->conf, CONF_bell_wavefile,
                      filename_from_str("/tmp/putty-bell-test.wav"));
    if (!putty_bridge_termwin_bell_wavefile_path(btw, wavepath, sizeof(wavepath))) {
        putty_bridge_termwin_free(btw);
        return 8;
    }
    if (strcmp(wavepath, "/tmp/putty-bell-test.wav") != 0) {
        putty_bridge_termwin_free(btw);
        return 9;
    }

    smoke_bell_mode = -1;
    win_bell(mac_termwin_get_termwin(btw->mtw), BELL_WAVEFILE);
    if (smoke_bell_mode != PUTTY_BRIDGE_BELL_WAVEFILE) {
        putty_bridge_termwin_free(btw);
        return 10;
    }

    putty_bridge_termwin_free(btw);
    return 0;
}

static bool smoke_term_has_char(
    Terminal *term, int x, int y, wchar_t expect)
{
    termline *tl = term_get_line(term, y);
    bool found = false;

    if (tl && 0 <= x && x < tl->cols)
        found = (tl->chars[x].chr == expect);
    term_release_line(tl);
    return found;
}

int putty_bridge_termwin_exit_smoke(void)
{
    PuttyBridgeTermWin *btw;
    int start_x, start_y, end_x, end_y, rc;

    btw = putty_bridge_termwin_new();
    if (!putty_bridge_termwin_init_demo(btw)) {
        putty_bridge_termwin_free(btw);
        return 1;
    }
    if (!btw->demo_ldisc) {
        putty_bridge_termwin_free(btw);
        return 2;
    }
    if (putty_bridge_termwin_cols(btw) != 80 ||
        putty_bridge_termwin_rows(btw) != 24) {
        putty_bridge_termwin_free(btw);
        return 3;
    }

    term_get_cursor_position(btw->term, &start_x, &start_y);
    putty_bridge_termwin_key_bytes(btw, -1, "q", 1);
    term_update(btw->term);

    if (!smoke_term_has_char(btw->term, start_x, start_y, CSET_ASCII | 'q')) {
        putty_bridge_termwin_free(btw);
        return 4;
    }

    term_get_cursor_position(btw->term, &end_x, &end_y);
    if (end_x != start_x + 1 || end_y != start_y) {
        putty_bridge_termwin_free(btw);
        return 5;
    }

    putty_bridge_termwin_paint(btw, 0, 0, 79, 23);

    rc = putty_bridge_termwin_perf_paint_benchmark(btw, 120, 16.67);
    if (rc != 0) {
        putty_bridge_termwin_free(btw);
        return 6;
    }

    putty_bridge_termwin_free(btw);
    return 0;
}

static int smoke_bridge_redraw_requests;

static void smoke_bridge_request_redraw(void *ctx, MacTermWinRect dirty)
{
    (void)ctx;
    (void)dirty;
    smoke_bridge_redraw_requests++;
}

int putty_bridge_termwin_seat_output_exit_smoke(void)
{
    PuttyBridgeTermWin *btw;
    MacTermWinCallbacks callbacks;
    static const char line[] = "seat output smoke\r\n";

    smoke_bridge_redraw_requests = 0;

    btw = putty_bridge_termwin_new();
    if (!putty_bridge_termwin_init_session(btw)) {
        putty_bridge_termwin_free(btw);
        return 1;
    }

    memset(&callbacks, 0, sizeof(callbacks));
    callbacks.request_redraw = smoke_bridge_request_redraw;
    mac_termwin_set_callbacks(btw->mtw, &callbacks, NULL);

    putty_bridge_termwin_feed(btw, line, sizeof(line) - 1);
    if (smoke_bridge_redraw_requests < 1) {
        putty_bridge_termwin_free(btw);
        return 2;
    }

    putty_bridge_termwin_free(btw);
    return 0;
}

void putty_bridge_set_parent_window(void *nswindow)
{
    mac_gui_dialogs_set_parent_window(nswindow);
}

int putty_bridge_termwin_seat_dialogs_exit_smoke(void)
{
    PuttyBridgeTermWin *btw;
    Seat *seat;
    const SeatDialogPromptDescriptions *descs;
    int rc;

    rc = mac_gui_seat_dialogs_smoke();
    if (rc != 0)
        return rc;

    btw = putty_bridge_termwin_new();
    if (!putty_bridge_termwin_init_session(btw)) {
        putty_bridge_termwin_free(btw);
        return 100;
    }

    seat = mac_gui_seat_get_seat(btw->seat);
    descs = seat_prompt_descriptions(seat);
    if (!descs || strcmp(descs->hk_accept_action, "click Accept") != 0) {
        putty_bridge_termwin_free(btw);
        return 101;
    }

    putty_bridge_termwin_free(btw);
    return 0;
}

int putty_bridge_termwin_eventloop_exit_smoke(void)
{
    PuttyBridgeTermWin *btw;
    int rc;

    rc = putty_bridge_eventloop_exit_smoke();
    if (rc != 0)
        return rc;

    putty_bridge_eventloop_start();

    btw = putty_bridge_termwin_new();
    if (!putty_bridge_termwin_init_session(btw)) {
        putty_bridge_termwin_free(btw);
        return 100;
    }

    putty_bridge_termwin_free(btw);
    return 0;
}

int putty_bridge_termwin_window_exit_smoke(void)
{
    PuttyConf *conf;
    PuttyBridgeTermWin *btw;
    bool connect;
    PuttyConf *parsed = NULL;
    char *argv[] = { (char *)"putty", (char *)"--help", NULL };
    PuttyBridgeCmdlineAction action;

    conf = putty_conf_new();
    if (!conf)
        return 1;
    putty_conf_set_host(conf, "example.com");
    /* Non-default Columns×Rows must survive putty_bridge_termwin_open. */
    conf_set_int(conf->conf, CONF_width, 218);
    conf_set_int(conf->conf, CONF_height, 32);
    if (!putty_conf_warn_on_close(conf)) {
        putty_conf_free(conf);
        return 2;
    }

    btw = putty_bridge_termwin_new();
    if (!putty_bridge_termwin_open(btw, conf, false)) {
        putty_conf_free(conf);
        putty_bridge_termwin_free(btw);
        return 3;
    }
    if (!putty_bridge_termwin_session_is_active(btw)) {
        putty_conf_free(conf);
        putty_bridge_termwin_free(btw);
        return 4;
    }
    if (!putty_bridge_termwin_should_warn_on_close(btw)) {
        putty_conf_free(conf);
        putty_bridge_termwin_free(btw);
        return 5;
    }
    if (putty_bridge_termwin_cols(btw) != 218 ||
        putty_bridge_termwin_rows(btw) != 32) {
        putty_conf_free(conf);
        putty_bridge_termwin_free(btw);
        return 7;
    }
    {
        uint8_t r = 0, g = 0, b = 0;
        /* Default Foreground (OSC4 index 256) from Conf Colour0. */
        if (!putty_bridge_termwin_palette_colour(btw, 256, &r, &g, &b) ||
            r != 187 || g != 187 || b != 187) {
            putty_conf_free(conf);
            putty_bridge_termwin_free(btw);
            return 8;
        }
    }

    action = putty_bridge_process_command_line(
        2, argv, &parsed, &connect);
    if (action != PUTTY_BRIDGE_CMDLINE_EXIT_HELP) {
        putty_conf_free(conf);
        putty_bridge_termwin_free(btw);
        if (parsed)
            putty_conf_free(parsed);
        return 6;
    }

    putty_conf_free(conf);
    putty_bridge_termwin_free(btw);
    return 0;
}

static void putty_bridge_termwin_specials_smoke_cb(void *ctx)
{
    (*(int *)ctx)++;
}

int putty_bridge_termwin_specials_exit_smoke(void)
{
    int smoke_specials_cb_count = 0;
    PuttyBridgeTermWin *btw;
    PuttyBridgeSessionSpecial specials[8];

    btw = putty_bridge_termwin_new();
    if (!btw)
        return 1;

    putty_bridge_termwin_set_specials_menu_callback(
        btw, putty_bridge_termwin_specials_smoke_cb, &smoke_specials_cb_count);

    if (!putty_bridge_termwin_open(btw, NULL, false)) {
        putty_bridge_termwin_free(btw);
        return 2;
    }

    if (putty_bridge_termwin_has_specials(btw)) {
        putty_bridge_termwin_free(btw);
        return 3;
    }

    if (putty_bridge_termwin_copy_specials(btw, specials, lenof(specials)) != 0) {
        putty_bridge_termwin_free(btw);
        return 4;
    }

    if (smoke_specials_cb_count < 1) {
        putty_bridge_termwin_free(btw);
        return 5;
    }

    putty_bridge_termwin_send_special(btw, putty_bridge_special_code_sep(), 0);

    putty_bridge_termwin_free(btw);
    return 0;
}

static void putty_bridge_termwin_eventlog_smoke_cb(void *ctx)
{
    (*(int *)ctx)++;
}

int putty_bridge_termwin_eventlog_smoke(void)
{
    int smoke_cb_count = 0;
    PuttyBridgeTermWin *btw;
    char line[256];
    size_t i;
    size_t expected;

    btw = putty_bridge_termwin_new();
    if (!btw)
        return 1;

    putty_bridge_termwin_set_eventlog_callback(
        btw, putty_bridge_termwin_eventlog_smoke_cb, &smoke_cb_count);

    if (!putty_bridge_termwin_open(btw, NULL, false)) {
        putty_bridge_termwin_free(btw);
        return 2;
    }

    if (putty_bridge_termwin_eventlog_count(btw) != 0) {
        putty_bridge_termwin_free(btw);
        return 3;
    }

    for (i = 0; i < LOGEVENT_INITIAL_MAX + LOGEVENT_CIRCULAR_MAX + 3; i++) {
        char msg[64];
        sprintf(msg, "event-%zu", i);
        putty_bridge_termwin_eventlog_append_test(btw, msg);
    }

    expected = LOGEVENT_INITIAL_MAX + LOGEVENT_CIRCULAR_MAX;
    if (putty_bridge_termwin_eventlog_count(btw) != expected) {
        putty_bridge_termwin_free(btw);
        return 4;
    }
    if (smoke_cb_count != (int)(LOGEVENT_INITIAL_MAX + LOGEVENT_CIRCULAR_MAX + 3)) {
        putty_bridge_termwin_free(btw);
        return 5;
    }
    if (!putty_bridge_termwin_eventlog_line(btw, 0, line, sizeof(line))) {
        putty_bridge_termwin_free(btw);
        return 6;
    }
    if (!strstr(line, "event-0")) {
        putty_bridge_termwin_free(btw);
        return 7;
    }
    /* After ring wrap, GTK replaces the oldest circular slot with "..". */
    if (!putty_bridge_termwin_eventlog_line(
            btw, LOGEVENT_INITIAL_MAX, line, sizeof(line))) {
        putty_bridge_termwin_free(btw);
        return 8;
    }
    if (strcmp(line, "..") != 0) {
        putty_bridge_termwin_free(btw);
        return 9;
    }
    if (!putty_bridge_termwin_eventlog_line(
            btw, expected - 1, line, sizeof(line))) {
        putty_bridge_termwin_free(btw);
        return 10;
    }
    if (!strstr(line, "event-258")) {
        putty_bridge_termwin_free(btw);
        return 11;
    }

    putty_bridge_termwin_free(btw);
    return 0;
}
