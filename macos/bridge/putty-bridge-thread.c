/*
 * putty-bridge-thread.c — main-thread verification (Phase 3.5).
 */

#include "putty-bridge-thread.h"

#if defined(__APPLE__)
#include <pthread.h>
#endif

bool putty_bridge_is_main_thread(void)
{
#if defined(__APPLE__)
    return pthread_main_np() != 0;
#else
    return true;
#endif
}

#if !defined(NDEBUG)
#include <assert.h>
#include <stdio.h>

void putty_bridge_assert_main_thread(const char *function)
{
    if (!putty_bridge_is_main_thread()) {
        fprintf(stderr,
                "PuttyBridge: %s must be called on the AppKit main thread\n",
                function ? function : "?");
        assert(false && "PuttyBridge API must run on the AppKit main thread");
    }
}
#endif

int putty_bridge_thread_smoke(void)
{
    PUTTY_BRIDGE_ASSERT_MAIN_THREAD();
    return putty_bridge_is_main_thread() ? 0 : -1;
}
