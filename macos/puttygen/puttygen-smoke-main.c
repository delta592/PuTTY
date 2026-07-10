/*
 * puttygen-smoke-main.c — Phase 7.3 headless smoke harness.
 */

#include <stdio.h>
#include <stdlib.h>

#include "puttygen-bridge.h"

int main(void)
{
    int rc = puttygen_bridge_smoke();
    if (rc != 0) {
        fprintf(stderr, "puttygen_bridge_smoke failed: %d\n", rc);
        return EXIT_FAILURE;
    }
    fputs("putty-mac-puttygen-smoke: ok\n", stdout);
    return EXIT_SUCCESS;
}
