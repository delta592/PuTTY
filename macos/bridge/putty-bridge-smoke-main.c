/*
 * putty-bridge-smoke-main.c — shared main() for bridge smoke / exit harnesses.
 *
 * Each executable sets PUTTY_BRIDGE_SMOKE_FUNC and PUTTY_SMOKE_OK_MSG via CMake
 * target_compile_definitions.
 */

#include <stdio.h>
#include <stdlib.h>

#include "putty-bridge.h"
#include "putty-bridge-termwin.h"

#ifndef PUTTY_BRIDGE_SMOKE_FUNC
#error "PUTTY_BRIDGE_SMOKE_FUNC must be defined by the CMake target"
#endif

#ifndef PUTTY_SMOKE_OK_MSG
#error "PUTTY_SMOKE_OK_MSG must be defined by the CMake target"
#endif

#ifndef PUTTY_SMOKE_LABEL
#define PUTTY_SMOKE_LABEL PUTTY_SMOKE_OK_MSG
#endif

#define PUTTY_BRIDGE_SMOKE_PASTE2(a, b) a##b
#define PUTTY_BRIDGE_SMOKE_PASTE(a, b) PUTTY_BRIDGE_SMOKE_PASTE2(a, b)
#define putty_bridge_smoke_run PUTTY_BRIDGE_SMOKE_PASTE(, PUTTY_BRIDGE_SMOKE_FUNC)

int main(void)
{
    int rc = putty_bridge_smoke_run();

    if (rc != 0) {
        fprintf(stderr, "%s failed: %d\n", PUTTY_SMOKE_LABEL, rc);
        return EXIT_FAILURE;
    }

    fputs(PUTTY_SMOKE_OK_MSG "\n", stdout);
    return EXIT_SUCCESS;
}
