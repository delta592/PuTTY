#include <stdio.h>
#include <stdlib.h>

#include "putty-bridge-termwin.h"

int main(void)
{
    int rc = putty_bridge_termwin_input_smoke();
    if (rc != 0) {
        fprintf(stderr, "putty_bridge_termwin_input_smoke failed: %d\n", rc);
        return EXIT_FAILURE;
    }
    fputs("putty-bridge-termwin-input-smoke: ok\n", stdout);
    return EXIT_SUCCESS;
}
