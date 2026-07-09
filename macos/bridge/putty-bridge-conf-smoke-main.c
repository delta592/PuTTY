#include "putty-bridge.h"

int main(void)
{
    return putty_bridge_conf_smoke() == 0 ? 0 : 1;
}
