/*
 * Platform symbols required by putty-mac-seat-smoke-c (Phase 5.1).
 */

#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "putty.h"
#include "ssh.h"

const bool share_can_be_downstream = true;
const bool share_can_be_upstream = true;

const struct BackendVtable *select_backend(Conf *conf)
{
    const struct BackendVtable *vt =
        backend_vt_from_proto(conf_get_int(conf, CONF_protocol));
    return vt;
}

char *platform_get_x_display(void)
{
    return NULL;
}

void old_keyfile_warning(void)
{
}

void cmdline_error(const char *fmt, ...)
{
    va_list ap;

    fputs("putty-mac-seat-smoke: ", stderr);
    va_start(ap, fmt);
    vfprintf(stderr, fmt, ap);
    va_end(ap);
    fputc('\n', stderr);
    exit(1);
}
