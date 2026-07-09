/*
 * C entry point for Phase 3 exit validation (main pthread guaranteed).
 */

#include <stdio.h>
#include "putty-bridge.h"

int main(void)
{
    return putty_bridge_phase3_exit_test() == 0 ? 0 : 1;
}
