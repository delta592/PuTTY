/*
 * Platform stubs required before the full macOS front end exists (Phase 5).
 */

#include "putty.h"

char *x_get_default(const char *key)
{
    (void)key;
    return NULL;
}
