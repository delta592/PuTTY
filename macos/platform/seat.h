/*
 * macos/platform/seat.h — MacGuiSeat per-window session (Phase 5.1).
 *
 * MacGuiSeat owns the embedded MacTermWin, Terminal, Backend, Ldisc, and
 * LogPolicy for one AppKit terminal window. Swift / the bridge sets
 * MacTermWinCallbacks on the embedded termwin for view integration.
 */

#ifndef PUTTY_MACOS_PLATFORM_SEAT_H
#define PUTTY_MACOS_PLATFORM_SEAT_H

#include "putty.h"
#include "terminal.h"
#include "mac-gui-seat.h"
#include "termwin.h"

#ifdef __cplusplus
extern "C" {
#endif

/**
 * Optional callbacks for session-level events (exit, logging, menus).
 * MacTermWin view callbacks are configured separately on the embedded termwin.
 */
typedef struct MacGuiSeatCallbacks {
    void (*on_remote_exit)(void *ctx, int exitcode);
    void (*on_connection_fatal)(void *ctx, const char *msg);
    void (*on_nonfatal)(void *ctx, const char *msg);
    void (*on_update_specials_menu)(void *ctx);
    void (*on_eventlog)(void *ctx, const char *event);
    /**
     * Return 2 overwrite, 1 append, 0 cancel, or -1 to answer later via
     * callback().
     */
    int (*on_askappend)(
        void *ctx, const char *path,
        void (*callback)(void *ctx, int result), void *cbctx);
    void (*on_set_busy_status)(void *ctx, BusyStatus status);
    void (*on_echoedit_update)(void *ctx, bool echoing, bool editing);
} MacGuiSeatCallbacks;

struct MacGuiSeat {
    struct MacGuiSeatListNode listnode;

    Seat seat;
    MacTermWin termwin;
    LogPolicy logpolicy;

    Conf *conf;
    Terminal *term;
    Ldisc *ldisc;
    Backend *backend;
    Backend null_backend;
    LogContext *logctx;
    struct unicode_data ucsdata;

    cmdline_get_passwd_input_state cmdline_get_passwd_state;

    MacGuiSeatCallbacks callbacks;
    void *callback_ctx;

    bool started;
    bool exited;
    BusyStatus busy_status;
    bool echoing;
    bool editing;
};

MacGuiSeat *mac_gui_seat_new(const Conf *conf);
void mac_gui_seat_free(MacGuiSeat *seat);

void mac_gui_seat_set_callbacks(
    MacGuiSeat *seat, const MacGuiSeatCallbacks *callbacks, void *ctx);

bool mac_gui_seat_start(MacGuiSeat *seat);
bool mac_gui_seat_start_local_echo(MacGuiSeat *seat);
void mac_gui_seat_destroy_connection(MacGuiSeat *seat);
void mac_gui_seat_reconfigure(MacGuiSeat *seat, const Conf *conf);

/**
 * True when the previous backend has exited and the session can be
 * restarted (Session → Restart Session). Mirrors GTK restartitem.
 */
bool mac_gui_seat_can_restart(const MacGuiSeat *seat);

/**
 * Restart after remote exit: log, term_pwron, clear exited, start backend.
 * Returns false if can_restart is false or start fails.
 */
bool mac_gui_seat_restart(MacGuiSeat *seat);

Seat *mac_gui_seat_get_seat(MacGuiSeat *seat);
MacTermWin *mac_gui_seat_get_termwin(MacGuiSeat *seat);
Terminal *mac_gui_seat_get_terminal(MacGuiSeat *seat);
Backend *mac_gui_seat_get_backend(MacGuiSeat *seat);
Ldisc *mac_gui_seat_get_ldisc(MacGuiSeat *seat);
Conf *mac_gui_seat_get_conf(MacGuiSeat *seat);
LogContext *mac_gui_seat_get_logctx(MacGuiSeat *seat);

/** Run pending toplevel callbacks (e.g. term_update) after seat output. */
void mac_gui_seat_flush_display(MacGuiSeat *seat);

/** Phase 5.1 smoke: create seat, local-echo linkage, feed output, destroy. */
int mac_gui_seat_smoke(void);

/** Phase 5.2 smoke: seat.output schedules a TermWin refresh. */
int mac_gui_seat_output_smoke(void);

/** True when the session has started and not yet exited (Phase 5.5). */
bool mac_gui_seat_is_active(MacGuiSeat *seat);

/** True when CONF_warn_on_close applies to this window (Phase 5.5). */
bool mac_gui_seat_should_warn_on_close(MacGuiSeat *seat);

/** Backend-specific close warning, or NULL. Caller must sfree() if non-NULL. */
char *mac_gui_seat_close_warn_text(MacGuiSeat *seat);

#ifdef __cplusplus
}
#endif

#endif /* PUTTY_MACOS_PLATFORM_SEAT_H */
