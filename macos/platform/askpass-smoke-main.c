/*
 * askpass-smoke-main.c — Phase 7.4 headless check for AppKit askpass.
 *
 * Uses PUTTY_ASKPASS_RESPONSE so no GUI is required.
 */

#include <stdio.h>
#include <stdlib.h>
#include <stdarg.h>
#include <string.h>

#include "putty.h"

void modalfatalbox(const char *fmt, ...)
{
    va_list ap;
    fputs("FATAL: ", stderr);
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

int main(void)
{
    bool success = false;
    char *result;
    const char *expect = "smoke-passphrase";

    setenv("PUTTY_ASKPASS_RESPONSE", expect, 1);

    result = gtk_askpass_main("macos", "Askpass smoke", "Enter test:", &success);
    if (!success || !result) {
        fprintf(stderr, "putty-mac-askpass-smoke: askpass failed\n");
        sfree(result);
        return 1;
    }
    if (strcmp(result, expect) != 0) {
        fprintf(stderr, "putty-mac-askpass-smoke: got \"%s\"\n", result);
        sfree(result);
        return 2;
    }
    sfree(result);

    puts("putty-mac-askpass-smoke: ok");
    return 0;
}
