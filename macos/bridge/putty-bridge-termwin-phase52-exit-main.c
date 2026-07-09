#include <stdio.h>
#include <stdlib.h>

#include "putty-bridge-termwin.h"

int main(void)
{
    int rc = putty_bridge_termwin_phase52_exit_smoke();
    if (rc != 0) {
        fprintf(stderr, "putty_bridge_termwin_phase52_exit_smoke failed: %d\n", rc);
        return EXIT_FAILURE;
    }
    fputs("putty-bridge-termwin-phase52-exit: ok\n", stdout);
    return EXIT_SUCCESS;
}
