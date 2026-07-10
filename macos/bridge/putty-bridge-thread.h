/*
 * putty-bridge-thread.h — main-thread checks for PuttyBridge (Phase 3.5).
 *
 * Not exported to Swift; include from bridge implementation files only.
 */

#ifndef PUTTY_MACOS_PUTTY_BRIDGE_THREAD_H
#define PUTTY_MACOS_PUTTY_BRIDGE_THREAD_H

#include <stdbool.h>

bool putty_bridge_is_main_thread(void);

#if !defined(NDEBUG)
void putty_bridge_assert_main_thread(const char *function);
#define PUTTY_BRIDGE_ASSERT_MAIN_THREAD() \
    putty_bridge_assert_main_thread(__func__)
#else
#define PUTTY_BRIDGE_ASSERT_MAIN_THREAD() ((void)0)
#endif

#endif /* PUTTY_MACOS_PUTTY_BRIDGE_THREAD_H */
