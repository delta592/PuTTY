#include <stdio.h>
#include <stdlib.h>

#include "putty-bridge.h"

int main(void)
{
    int rc = putty_bridge_phase5_exit_test();
    if (rc != 0) {
        fprintf(stderr, "putty_bridge_phase5_exit_test failed: %d\n", rc);
        return EXIT_FAILURE;
    }
    fputs("putty-bridge-phase5-exit: ok\n", stdout);
    return EXIT_SUCCESS;
}
