/*
 * macos/platform/eventloop-appkit.h — AppKit / Dispatch event-loop hooks (Phase 5.4).
 */

#ifndef PUTTY_MACOS_PLATFORM_EVENTLOOP_APPKIT_H
#define PUTTY_MACOS_PLATFORM_EVENTLOOP_APPKIT_H

#ifdef __cplusplus
extern "C" {
#endif

/** Schedule run_toplevel_callbacks() on the main dispatch queue. */
void mac_eventloop_schedule_toplevel_callbacks(void *ctx);

/** Run one CFRunLoop iteration (smoke tests / headless pump). */
void mac_eventloop_pump_once(void);

#ifdef __cplusplus
}
#endif

#endif /* PUTTY_MACOS_PLATFORM_EVENTLOOP_APPKIT_H */
