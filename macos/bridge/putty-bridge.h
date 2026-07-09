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
 * Session, configuration, and event-loop wrappers are added in Phases
 * 3.2–3.4. This header defines opaque types and version/build probes.
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
/* Opaque handles (defined in bridge implementation; Phase 3.2+) */

typedef struct PuttySession PuttySession;
typedef struct PuttyConf PuttyConf;

/*
 * PuttySession — live connection context (Seat + TermWin + backend).
 * PuttyConf    — session settings (Conf wrapper).
 *
 * Lifecycle and callback registration APIs arrive in Phase 3.2–3.4.
 */

#ifdef __cplusplus
}
#endif

#endif /* PUTTY_MACOS_PUTTY_BRIDGE_H */
