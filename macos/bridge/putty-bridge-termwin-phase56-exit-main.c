#include <stdio.h>
#include <stdlib.h>

#include "putty-bridge.h"
#include "putty-bridge-termwin.h"

int main(void)
{
    int rc = putty_bridge_termwin_phase56_exit_smoke();
    if (rc != 0) {
        fprintf(stderr, "putty_bridge_termwin_phase56_exit_smoke failed: %d\n", rc);
        return EXIT_FAILURE;
    }
    fputs("putty-bridge-termwin-phase56-exit: ok\n", stdout);
    return EXIT_SUCCESS;
}
