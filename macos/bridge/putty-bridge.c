/*
 * putty-bridge.c — C ↔ Swift bridge implementation.
 */

#include "putty-bridge.h"

int putty_bridge_version(void)
{
    return putty_bridge_api_version();
}

int putty_bridge_api_version(void)
{
    return PUTTY_BRIDGE_API_VERSION;
}

const char *putty_bridge_api_version_string(void)
{
    return "1";
}

const char *putty_bridge_buildinfo_platform(void)
{
    return "macOS (AppKit)";
}
