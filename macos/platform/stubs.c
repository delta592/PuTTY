/*
 * Platform stubs required before the full macOS front end exists (Phase 5).
 *
 * WORKAROUND: x_get_default is an X11 resource fallback on Unix/GTK; AppKit
 * has no X resources, so always return NULL (defaults come from Conf /
 * Application Support). — see .cursor/rules/agents.mdc
 */

#include "putty.h"

char *x_get_default(const char *key)
{
    (void)key;
    return NULL;
}
