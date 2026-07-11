/*
 * Smoke test for AppKit controlbox renderer (Phase 6.1).
 */

#include <stdio.h>
#include <stdlib.h>
#include <stdarg.h>

#include "putty.h"
#include "paths.h"

#include "config-appkit.h"

const unsigned cmdline_tooltype =
    TOOLTYPE_HOST_ARG |
    TOOLTYPE_PORT_ARG |
    TOOLTYPE_NO_VERBOSE_OPTION;

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
        return dupstr(PUTTY_MACOS_DEFAULT_SERIAL_LINE);
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
    if (!strcmp(name, "LogFileName")) {
        char *path = putty_macos_default_log_path();
        Filename *fn = filename_from_str(path && path[0] ? path : "putty.log");
        sfree(path);
        return fn;
    }
    return filename_from_str("");
}

int main(void)
{
    int rc = mac_config_controlbox_smoke();

    if (rc != 0) {
        fprintf(stderr, "mac_config_controlbox_smoke failed (%d)\n", rc);
        return EXIT_FAILURE;
    }

    puts("mac_config_controlbox_smoke: ok");

    rc = mac_config_settings_ux_smoke();
    if (rc != 0) {
        fprintf(stderr, "mac_config_settings_ux_smoke failed (%d)\n", rc);
        return EXIT_FAILURE;
    }

    rc = mac_config_ca_smoke();
    if (rc != 0) {
        fprintf(stderr, "mac_config_ca_smoke failed (%d)\n", rc);
        return EXIT_FAILURE;
    }

    return EXIT_SUCCESS;
}
