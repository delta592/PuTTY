/*
 * putty-bridge.h — public C API for the macOS AppKit GUI (Swift import).
 *
 * Swift imports this header through the PuttyBridge clang module
 * (macos/bridge/module.modulemap). Do not include putty.h or other
 * internal PuTTY headers from Swift.
 *
 * Design rules:
 *  - Prefer stable C wrapper functions over exposing PuTTY vtables or
 *    struct layouts to Swift.
 *  - Use @_cdecl / SWIFT_NAME in Swift only for test hooks; production
 *    code calls the C functions declared here.
 *
 * Memory and threading (Phase 3.5):
 *  - Call every PuttyBridge function on the AppKit main thread (main
 *    queue). PuTTY's seat, terminal, backend, and event-loop state are
 *    not synchronised for background use. Debug builds assert via
 *    pthread_main_np(); release builds rely on caller discipline.
 *  - Swift owns objects returned by putty_session_new() and
 *    putty_conf_new(); call the matching putty_*_free() when done.
 *  - putty_session_set_callbacks() stores callback function pointers and
 *    a context pointer only for the duration of the call; the bridge
 *    never retains Swift objects or blocks. Re-register callbacks before
 *    each use if Swift needs fresh context, or keep ctx stable for the
 *    session lifetime.
 *  - PuttySessionCallbacks fire synchronously from PuTTY C code on the
 *    main thread during putty_run_toplevel_callbacks() or I/O processing.
 */

#ifndef PUTTY_MACOS_PUTTY_BRIDGE_H
#define PUTTY_MACOS_PUTTY_BRIDGE_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>

#ifdef __cplusplus
extern "C" {
#endif

/* ---------------------------------------------------------------------- */
/* API versioning */

/** Increment when breaking the public C API visible to Swift. */
#define PUTTY_BRIDGE_API_VERSION 1

/** @deprecated Use putty_bridge_api_version(); kept for smoke tests. */
int putty_bridge_version(void);

/** Current PUTTY_BRIDGE_API_VERSION. */
int putty_bridge_api_version(void);

/** Human-readable API version string (e.g. "1"). */
const char *putty_bridge_api_version_string(void);

/* ---------------------------------------------------------------------- */
/* Build identification */

/** Platform string matching BUILDINFO_PLATFORM ("macOS (AppKit)"). */
const char *putty_bridge_buildinfo_platform(void);

/* ---------------------------------------------------------------------- */
/* Opaque handles */

typedef struct PuttySession PuttySession;
typedef struct PuttyConf PuttyConf;

/** Opaque PuTTY backend handle (see putty.h in C bridge code). */
struct Backend;

/* ---------------------------------------------------------------------- */
/* Session callbacks (Phase 3.2) */

/** Pixel-space dirty region; zero width/height means full terminal area. */
typedef struct PuttyBridgeRect {
    double x, y, width, height;
} PuttyBridgeRect;

typedef struct PuttySessionCallbacks {
    void (*on_output)(void *ctx, const void *data, size_t len);
    void (*on_title_changed)(void *ctx, const char *title);
    void (*on_bell)(void *ctx, int mode);
    void (*on_exit)(void *ctx);
    void (*on_request_redraw)(void *ctx, PuttyBridgeRect dirtyPixels);
} PuttySessionCallbacks;

void putty_session_set_callbacks(
    PuttySession *session,
    const PuttySessionCallbacks *callbacks,
    void *ctx);

/**
 * Create a session (Seat + Terminal + stub TermWin). Does not connect yet;
 * call putty_session_start() to open the backend.
 *
 * If conf is NULL, default settings are loaded and owned by the session.
 * If conf is non-NULL, settings are copied from conf (caller keeps conf).
 */
PuttySession *putty_session_new(const PuttyConf *conf);

void putty_session_free(PuttySession *session);

/** Open the backend and create the line discipline. */
void putty_session_start(PuttySession *session);

/** Apply new settings to a live or idle session. */
void putty_session_reconfigure(PuttySession *session, const PuttyConf *conf);

/** For backend_unthrottle and other C-side backend access (Phase 3.4). */
struct Backend *putty_session_get_backend(PuttySession *session);

/* ---------------------------------------------------------------------- */
/* Configuration (Phase 3.3) */

/** Protocol values match PuTTY PROT_* constants. */
enum PuttyConfProtocol {
    PUTTY_CONF_PROT_RAW = 0,
    PUTTY_CONF_PROT_TELNET = 1,
    PUTTY_CONF_PROT_RLOGIN = 2,
    PUTTY_CONF_PROT_SSH = 3,
    PUTTY_CONF_PROT_SSHCONN = 4,
    PUTTY_CONF_PROT_SERIAL = 5,
    PUTTY_CONF_PROT_SUPDUP = 6,
};

/** Small set of boolean settings exposed for the connection dialog. */
typedef enum PuttyConfBoolKey {
    PUTTY_CONF_BOOL_TCP_NODELAY,
    PUTTY_CONF_BOOL_TCP_KEEPALIVES,
} PuttyConfBoolKey;

/** Load default settings (same as "Default Settings" saved session). */
PuttyConf *putty_conf_new(void);

/** Deep copy of all settings. */
PuttyConf *putty_conf_copy(const PuttyConf *conf);

void putty_conf_free(PuttyConf *conf);

/**
 * Load a named saved session into conf. Returns false if the session
 * did not exist (conf is still filled with usable defaults).
 */
bool putty_conf_load_session(PuttyConf *conf, const char *session_name);

/** Persist conf under session_name. Returns false on I/O error. */
bool putty_conf_save_session(PuttyConf *conf, const char *session_name);

/** String getters return pointers owned by conf (valid until next mutation). */
const char *putty_conf_get_host(const PuttyConf *conf);
void putty_conf_set_host(PuttyConf *conf, const char *host);

const char *putty_conf_get_username(const PuttyConf *conf);
void putty_conf_set_username(PuttyConf *conf, const char *username);

int putty_conf_get_port(const PuttyConf *conf);
void putty_conf_set_port(PuttyConf *conf, int port);

int putty_conf_get_protocol(const PuttyConf *conf);
void putty_conf_set_protocol(PuttyConf *conf, int protocol);

/** Well-known default port for a PUTTY_CONF_PROT_* value. */
int putty_conf_default_port_for_protocol(int protocol);

bool putty_conf_get_bool(const PuttyConf *conf, PuttyConfBoolKey key);
void putty_conf_set_bool(PuttyConf *conf, PuttyConfBoolKey key, bool value);

/** True when conf has enough information to open a network/serial session. */
bool putty_conf_launchable(const PuttyConf *conf);

/** Value of the WarnOnClose setting. */
bool putty_conf_warn_on_close(const PuttyConf *conf);

/* ---------------------------------------------------------------------- */
/* Command line (Phase 5.5) */

typedef enum PuttyBridgeCmdlineAction {
    PUTTY_BRIDGE_CMDLINE_LAUNCH = 0,
    PUTTY_BRIDGE_CMDLINE_EXIT_HELP,
    PUTTY_BRIDGE_CMDLINE_EXIT_VERSION,
    PUTTY_BRIDGE_CMDLINE_EXIT_OK,
    /** Show Host CA config (modal) then exit — `-host_ca` / `--host-ca`. */
    PUTTY_BRIDGE_CMDLINE_HOST_CA,
    /**
     * Confirm then delete Application Support data (`-cleanup`).
     * Swift shows an NSAlert, then calls putty_bridge_cleanup_all().
     */
    PUTTY_BRIDGE_CMDLINE_CLEANUP,
} PuttyBridgeCmdlineAction;

/**
 * Parse argv (including argv[0]). On LAUNCH, *conf_out receives a new PuttyConf
 * owned by the caller. *connect_out is true when a connection should start
 * immediately (host or launchable -load).
 */
PuttyBridgeCmdlineAction putty_bridge_process_command_line(
    int argc, char **argv, PuttyConf **conf_out, bool *connect_out);

void putty_bridge_print_help(FILE *fp);
void putty_bridge_print_version(FILE *fp);

/* ---------------------------------------------------------------------- */
/* App launch / initial config (Phase 6.3) */

/**
 * Called when C wants Swift to open a session window.
 * - conf non-NULL: caller transfers ownership; Swift must putty_conf_free().
 * - conf NULL: quit request (initial config Cancel with no open windows).
 * - connect: true when conf is launchable and a backend should start.
 */
typedef void (*PuttyBridgeOpenSessionFn)(
    void *ctx, PuttyConf *conf, bool connect);

void putty_bridge_set_open_session_callback(
    PuttyBridgeOpenSessionFn fn, void *ctx);

/** Track live session windows (for Cancel → quit when none remain). */
void putty_bridge_session_window_opened(void);
void putty_bridge_session_window_closed(void);
int putty_bridge_open_session_window_count(void);

/** True when conf lacks a host/session suitable for immediate connect. */
bool putty_bridge_needs_initial_config(const PuttyConf *conf);

/**
 * Start the app: if connect_immediately and conf is host-ok, open a session
 * window; otherwise show initial_config_box. Takes ownership of conf.
 */
void putty_bridge_start_app(PuttyConf *conf, bool connect_immediately);

/** Session → New Session: show initial config box with defaults. */
void putty_bridge_launch_new_session(void);

/** Session → Saved Sessions: open named session (or config if incomplete). */
void putty_bridge_launch_saved_session(const char *session_name);

/**
 * Copy saved-session names (skips "Default Settings") into out[0..max_out-1].
 * Each string is heap-allocated; free with putty_bridge_free_string().
 * Returns the number of names written (may be less than total if truncated).
 */
size_t putty_bridge_copy_saved_session_names(char **out, size_t max_out);

/** Free a string returned by putty_bridge_copy_saved_session_names(). */
void putty_bridge_free_string(char *s);

/**
 * Delete all PuTTY Application Support data (sessions, host keys, seed).
 * Used after the user confirms `-cleanup`.
 */
void putty_bridge_cleanup_all(void);

/**
 * Show the Host CA configuration dialog modally (Phase 6.5).
 * Used by `-host-ca` / `--host_ca` and returns when the user closes it.
 */
void putty_bridge_show_host_ca_config(void);

/**
 * Parse an ssh:// or putty:// URL into conf. Returns true on success.
 * putty://load/SESSION or putty://SESSION loads a saved session;
 * ssh://[user@]host[:port][/] sets host/user/port for SSH.
 */
bool putty_bridge_conf_from_url(PuttyConf *conf, const char *url);

/** Headless smoke for launch / need-config decisions. Returns 0 on OK. */
int putty_bridge_launch_smoke(void);

/* ---------------------------------------------------------------------- */
/* Event loop (Phase 3.4) */

/** Millisecond clock compatible with putty_run_timers() (GETTICKCOUNT). */
uint64_t putty_bridge_now_ms(void);

/** Initialise uxsel and toplevel-callback notification (idempotent). */
void putty_bridge_eventloop_init(void);

/** Start AppKit event-loop integration (timers + dispatch sources). */
void putty_bridge_eventloop_start(void);

/** Run one CFRunLoop iteration (smoke tests). */
void putty_bridge_eventloop_pump_once(void);

/** Run due PuTTY timers; pass the same clock used for scheduling. */
void putty_run_timers(uint64_t now_ms);

bool putty_toplevel_callback_pending(void);
void putty_run_toplevel_callbacks(void);

/** Feed keyboard/paste bytes to the session line discipline. */
size_t putty_session_output(PuttySession *session, const void *data, size_t len);

/** Poll readiness bits (match SELECT_* / uxsel rwx values). */
#define PUTTY_BRIDGE_POLL_R 1
#define PUTTY_BRIDGE_POLL_W 2
#define PUTTY_BRIDGE_POLL_X 4

typedef struct PuttyBridgePollFd {
    int fd;
    unsigned int rwx;
} PuttyBridgePollFd;

typedef struct PuttyPollWrapper PuttyPollWrapper;

PuttyPollWrapper *putty_pollwrapper_new(void);
void putty_pollwrapper_free(PuttyPollWrapper *wrapper);
void putty_pollwrapper_clear(PuttyPollWrapper *wrapper);

/** Register all uxsel fds in pw (mirrors unix/cliloop.c setup). */
void putty_uxsel_fill_pollfds(PuttyPollWrapper *wrapper);

/** List uxsel fds for DispatchSource registration (truncates if max_out small). */
size_t putty_uxsel_list_fds(PuttyBridgePollFd *out, size_t max_out);

/** Deliver fd readiness to uxsel after poll or DispatchSource fires. */
void putty_uxsel_select_result(int fd, unsigned int rwx_event);

int putty_pollwrapper_poll_instant(PuttyPollWrapper *wrapper);
int putty_pollwrapper_poll_timeout(PuttyPollWrapper *wrapper, int timeout_ms);
void putty_pollwrapper_process_events(PuttyPollWrapper *wrapper);

/* ---------------------------------------------------------------------- */
/* Threading (Phase 3.5) */

/** True when called on the process main thread (AppKit main queue). */
bool putty_bridge_is_main_thread(void);

/* ---------------------------------------------------------------------- */
/* Smoke tests (not for production use) */

int putty_bridge_session_smoke(void);
int putty_bridge_conf_smoke(void);
int putty_bridge_eventloop_smoke(void);

/** Exit gate: DispatchSource timers + toplevel callbacks. Returns 0 on success. */
int putty_bridge_eventloop_exit_smoke(void);
int putty_bridge_thread_smoke(void);

/**
 * Live SSH integration test through MacGuiSeat + TermWin (default host
 * 192.168.0.19). Set PUTTY_BRIDGE_SSH_EXIT_SKIP=1 to skip.
 */
int putty_bridge_ssh_exit_test(void);

#include "putty-bridge-termwin.h"

#ifdef __cplusplus
}
#endif

#endif /* PUTTY_MACOS_PUTTY_BRIDGE_H */
