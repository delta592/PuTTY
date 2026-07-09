/*
 * putty-bridge-platform.c — platform symbols required by the bridge library.
 */

#include <stdlib.h>
#include <string.h>

#include "putty.h"

char *platform_default_s(const char *name)
{
    if (!strcmp(name, "TermType"))
        return dupstr(getenv("TERM") ? getenv("TERM") : "xterm-256color");
    if (!strcmp(name, "SerialLine"))
        return dupstr("/dev/tty.usbserial");
    return NULL;
}

bool platform_default_b(const char *name, bool def)
{
    (void)name;
    return def;
}

int platform_default_i(const char *name, int def)
{
    (void)name;
    return def;
}

FontSpec *platform_default_fontspec(const char *name)
{
    (void)name;
    return fontspec_new_default();
}

Filename *platform_default_filename(const char *name)
{
    if (!strcmp(name, "LogFileName"))
        return filename_from_str("putty.log");
    return filename_from_str("");
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

    fputs("putty-bridge: ", stderr);
    va_start(ap, fmt);
    vfprintf(stderr, fmt, ap);
    va_end(ap);
    fputc('\n', stderr);
    exit(1);
}
