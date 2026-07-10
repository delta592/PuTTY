/*
 * Smoke test for MacTermWin (Phase 4.1).
 */

#include <stdio.h>
#include <stdlib.h>
#include <stdarg.h>

#include "putty.h"

#include "termwin.h"

void modalfatalbox(const char *fmt, ...)
{
    va_list ap;

    va_start(ap, fmt);
    vfprintf(stderr, fmt, ap);
    va_end(ap);
    fputc('\n', stderr);
    exit(1);
}

void nonfatal(const char *fmt, ...)
{
    (void)fmt;
}

char *platform_default_s(const char *name)
{
    if (!strcmp(name, "TermType"))
        return dupstr(getenv("TERM"));
    if (!strcmp(name, "SerialLine"))
        return dupstr("/dev/ttyS0");
    return NULL;
}

bool platform_default_b(const char *name, bool def)
{
    return def;
}

int platform_default_i(const char *name, int def)
{
    return def;
}

FontSpec *platform_default_fontspec(const char *name)
{
    return fontspec_new_default();
}

Filename *platform_default_filename(const char *name)
{
    if (!strcmp(name, "LogFileName"))
        return filename_from_str("putty.log");
    return filename_from_str("");
}

int main(void)
{
    int rc = mac_termwin_smoke();

    if (rc != 0) {
        fprintf(stderr, "mac_termwin_smoke failed (%d)\n", rc);
        return EXIT_FAILURE;
    }

    puts("mac_termwin_smoke: ok");
    return EXIT_SUCCESS;
}
