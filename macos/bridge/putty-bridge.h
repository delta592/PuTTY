/*
 * putty-bridge.h — public C API for the macOS AppKit GUI (Swift import).
 *
 * Swift imports this header through the PuttyBridge clang module
 * (macos/bridge/module.modulemap). Do not include putty.h or other
 * internal PuTTY headers from Swift.
 *
 * Design rules (Phase 3.1):
 *  - Prefer stable C wrapper functions over exposing PuTTY vtables or
 *    struct layouts to Swift.
 *  - Use @_cdecl / SWIFT_NAME in Swift only for test hooks; production
 *    code calls the C functions declared here.
 *  - All PuTTY C entry points invoked through this bridge run on the
 *    main thread (AppKit main queue). Phase 3.5 adds debug assertions.
 *  - Swift owns objects returned by putty_*_new() functions; the bridge
 *    never retains Swift callbacks or contexts (Phase 3.2+).
 *
 * Session and configuration wrappers: Phase 3.2 (session object),
 * 3.3 (configuration access), 3.4 (event loop hooks).
 */

#ifndef PUTTY_MACOS_PUTTY_BRIDGE_H
#define PUTTY_MACOS_PUTTY_BRIDGE_H

#include <stddef.h>
#include <stdint.h>

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
/* Smoke test (Phase 3.2; not for production use) */

int putty_bridge_session_smoke(void);

#ifdef __cplusplus
}
#endif

#endif /* PUTTY_MACOS_PUTTY_BRIDGE_H */
