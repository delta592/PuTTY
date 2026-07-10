/*
 * pterm-app.c — pterm application constants for the macOS AppKit GUI.
 *
 * Mirrors unix/pterm.c. Linked into pterm-macos-bridge instead of
 * putty-bridge-app.c.
 */

#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>

#include "putty.h"

const bool buildinfo_gtk_relevant = false;

const bool use_event_log = false;
const bool new_session = false;
const bool saved_sessions = false;
const bool dup_check_launchable = false;
const bool use_pty_argv = true;

const bool share_can_be_downstream = false;
const bool share_can_be_upstream = false;

const unsigned cmdline_tooltype = TOOLTYPE_NONNETWORK;

/* pty.c defines pty_argv; keep a declaration-only expectation via platform.h. */

void noise_ultralight(NoiseSourceId id, unsigned long data)
{
    (void)id;
    (void)data;
}

const struct BackendVtable *select_backend(Conf *conf)
{
    (void)conf;
    return &pty_backend;
}

void initial_config_box(Conf *conf, post_dialog_fn_t after, void *afterctx)
{
    /*
     * No-op: open a window immediately. Protocol -1 hides the Connection
     * panel in Change Settings (config.c).
     */
    conf_set_int(conf, CONF_protocol, -1);
    after(afterctx, 1);
}

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

void setup(bool single)
{
    (void)single;
    settings_set_default_protocol(-1);
    /* NO_PTY_PRE_INIT on macOS: pty_pre_init() is a no-op. */
}

void cleanup_exit(int code)
{
    exit(code);
}
