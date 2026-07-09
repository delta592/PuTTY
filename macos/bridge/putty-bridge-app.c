/*
 * putty-bridge-app.c — PuTTY application constants for the macOS GUI bridge.
 *
 * Mirrors symbols normally defined in unix/putty.c for the GTK front end.
 */

#include <assert.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>

#include "putty.h"
#include "ssh.h"

#include "config-appkit.h"

const bool buildinfo_gtk_relevant = false;

const bool use_event_log = true;
const bool new_session = true;
const bool saved_sessions = true;
const bool dup_check_launchable = true;
const bool use_pty_argv = false;
char **pty_argv; /* unused in PuTTY.app; defined for link parity with pty stubs */

const bool share_can_be_downstream = true;
const bool share_can_be_upstream = true;

const unsigned cmdline_tooltype =
    TOOLTYPE_HOST_ARG |
    TOOLTYPE_PORT_ARG |
    TOOLTYPE_NO_VERBOSE_OPTION;

const struct BackendVtable *select_backend(Conf *conf)
{
    const struct BackendVtable *vt =
        backend_vt_from_proto(conf_get_int(conf, CONF_protocol));
    assert(vt != NULL);
    return vt;
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
    enable_dit();
    settings_set_default_protocol(be_default_protocol);
    {
        const struct BackendVtable *vt =
            backend_vt_from_proto(be_default_protocol);
        settings_set_default_port(0);
        if (vt)
            settings_set_default_port(vt->default_port);
    }
}

void initial_config_box(Conf *conf, post_dialog_fn_t after, void *afterctx)
{
    char *title = dupcat(appname, " Configuration");
    mac_config_create_box(title, conf, false, 0, after, afterctx);
    sfree(title);
}

void cleanup_exit(int code)
{
    sk_cleanup();
    random_save_seed();
    exit(code);
}
