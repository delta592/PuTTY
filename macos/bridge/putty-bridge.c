/*
 * putty-bridge.c — C ↔ Swift bridge implementation.
 */

#include "putty-bridge.h"

#include "putty-bridge-thread.h"

int putty_bridge_version(void)
{
    PUTTY_BRIDGE_ASSERT_MAIN_THREAD();
    return putty_bridge_api_version();
}

int putty_bridge_api_version(void)
{
    PUTTY_BRIDGE_ASSERT_MAIN_THREAD();
    return PUTTY_BRIDGE_API_VERSION;
}

const char *putty_bridge_api_version_string(void)
{
    PUTTY_BRIDGE_ASSERT_MAIN_THREAD();
    return "1";
}

const char *putty_bridge_buildinfo_platform(void)
{
    PUTTY_BRIDGE_ASSERT_MAIN_THREAD();
    return "macOS (AppKit)";
}
