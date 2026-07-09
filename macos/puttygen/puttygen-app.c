/*
 * puttygen-app.c — platform stubs for macOS PuTTYgen.app (Phase 7.3).
 */

#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>

#include "putty.h"

const bool buildinfo_gtk_relevant = false;

const char *const appname = "PuTTYgen";

void modalfatalbox(const char *fmt, ...)
{
    va_list ap;

    fputs("FATAL ERROR: ", stderr);
    va_start(ap, fmt);
    vfprintf(stderr, fmt, ap);
    va_end(ap);
    fputc('\n', stderr);
    exit(1);
}

void nonfatal(const char *fmt, ...)
{
    va_list ap;

    fputs("ERROR: ", stderr);
    va_start(ap, fmt);
    vfprintf(stderr, fmt, ap);
    va_end(ap);
    fputc('\n', stderr);
}

char *x_get_default(const char *key)
{
    (void)key;
    return NULL;
}

void cleanup_exit(int code)
{
    exit(code);
}

void old_keyfile_warning(void)
{
    /* CLI puttygen prints a warning; GUI can ignore for MVP. */
}
