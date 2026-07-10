/*
 * pterm-bridge-cmdline.c — macOS pterm command-line parsing (Phase 7.2).
 *
 * Mirrors the pterm subset of unix/main-gtk-simple.c: TOOLTYPE_NONNETWORK,
 * -e COMMAND, -pgpfp, help/version. X11-only flags (-geometry, -xrm, …)
 * are omitted on AppKit.
 */

#include <stdio.h>
#include <string.h>

#include "putty-bridge-internal.h"
#include "putty-bridge-thread.h"

#include "storage.h"

static bool pterm_bridge_cmdline_extra(
    CmdlineArg *arg, CmdlineArg *nextarg, bool do_everything, Conf *conf,
    PuttyBridgeCmdlineAction *action)
{
    const char *p = cmdline_arg_to_str(arg);

    (void)conf;

    if (!do_everything) {
        if (!strcmp(p, "-help") || !strcmp(p, "--help")) {
            *action = PUTTY_BRIDGE_CMDLINE_EXIT_HELP;
            return true;
        }
        if (!strcmp(p, "-version") || !strcmp(p, "--version")) {
            *action = PUTTY_BRIDGE_CMDLINE_EXIT_VERSION;
            return true;
        }
        if (!strcmp(p, "-pgpfp")) {
            pgp_fingerprints();
            *action = PUTTY_BRIDGE_CMDLINE_EXIT_OK;
            return true;
        }
        if (use_pty_argv && !strcmp(p, "-e")) {
            /* Consume in the do_everything pass. */
            return true;
        }
        return false;
    }

    if (!strcmp(p, "-help") || !strcmp(p, "--help")) {
        *action = PUTTY_BRIDGE_CMDLINE_EXIT_HELP;
        return true;
    }
    if (!strcmp(p, "-version") || !strcmp(p, "--version")) {
        *action = PUTTY_BRIDGE_CMDLINE_EXIT_VERSION;
        return true;
    }
    if (!strcmp(p, "-pgpfp")) {
        pgp_fingerprints();
        *action = PUTTY_BRIDGE_CMDLINE_EXIT_OK;
        return true;
    }
    if (use_pty_argv && !strcmp(p, "-e")) {
        if (!nextarg) {
            cmdline_error("-e expects a command");
            return true;
        }
        pty_argv = cmdline_arg_remainder(nextarg);
        return true;
    }
    if (p[0] == '-') {
        cmdline_error("unrecognized option \"%s\"", p);
    }
    return false;
}

PuttyBridgeCmdlineAction putty_bridge_process_command_line(
    int argc, char **argv, PuttyConf **conf_out, bool *connect_out)
{
    CmdlineArgList *arglist;
    size_t arglistpos;
    PuttyConf *conf;
    PuttyBridgeCmdlineAction action = PUTTY_BRIDGE_CMDLINE_LAUNCH;

    PUTTY_BRIDGE_ASSERT_MAIN_THREAD();

    if (conf_out)
        *conf_out = NULL;
    if (connect_out)
        *connect_out = false;

    if (argc < 1 || !argv)
        return PUTTY_BRIDGE_CMDLINE_LAUNCH;

    setup(true);

    conf = putty_conf_new();
    if (!conf)
        return PUTTY_BRIDGE_CMDLINE_LAUNCH;

    /* Ensure Connection panel stays hidden in Change Settings. */
    conf_set_int(conf->conf, CONF_protocol, -1);

    arglist = cmdline_arg_list_from_argv(argc, argv);
    arglistpos = 0;
    while (arglist->args[arglistpos]) {
        CmdlineArg *arg = arglist->args[arglistpos++];
        CmdlineArg *nextarg = arglist->args[arglistpos];
        int ret;

        if (pterm_bridge_cmdline_extra(arg, nextarg, false, conf->conf, &action)) {
            if (action != PUTTY_BRIDGE_CMDLINE_LAUNCH) {
                putty_conf_free(conf);
                return action;
            }
            /* -e: skip remainder in this pass */
            if (use_pty_argv && !strcmp(cmdline_arg_to_str(arg), "-e"))
                break;
            continue;
        }

        ret = cmdline_process_param(arg, nextarg, -1, conf->conf);
        if (ret == 2)
            arglistpos++;
    }

    arglistpos = 0;
    while (arglist->args[arglistpos]) {
        CmdlineArg *arg = arglist->args[arglistpos++];
        CmdlineArg *nextarg = arglist->args[arglistpos];
        int ret;

        if (pterm_bridge_cmdline_extra(arg, nextarg, true, conf->conf, &action)) {
            if (action != PUTTY_BRIDGE_CMDLINE_LAUNCH) {
                putty_conf_free(conf);
                return action;
            }
            if (use_pty_argv && !strcmp(cmdline_arg_to_str(arg), "-e"))
                break; /* remainder consumed into pty_argv */
            continue;
        }

        ret = cmdline_process_param(arg, nextarg, 1, conf->conf);
        if (ret == -2) {
            cmdline_error("option \"%s\" requires an argument",
                          cmdline_arg_to_str(arg));
        } else if (ret == 2) {
            arglistpos++;
        } else if (ret == 1) {
            continue;
        } else if (cmdline_arg_to_str(arg)[0] != '-') {
            continue;
        } else {
            cmdline_error("unrecognized option \"%s\"", cmdline_arg_to_str(arg));
        }
    }

    cmdline_run_saved(conf->conf);
    conf_set_int(conf->conf, CONF_protocol, -1);

    if (conf_out)
        *conf_out = conf;
    else
        putty_conf_free(conf);

    /*
     * Always open a session window and start the PTY (GTK pterm never
     * gates on conf_launchable / cmdline_host_ok).
     */
    if (connect_out)
        *connect_out = true;

    return PUTTY_BRIDGE_CMDLINE_LAUNCH;
}

void putty_bridge_print_help(FILE *fp)
{
    if (fprintf(fp,
                "pterm for macOS option summary:\n"
                "\n"
                "  -e COMMAND [ARGS...]  Execute command (consumes remaining args)\n"
                "  --help                Display this text\n"
                "  --version             Show version and build info\n"
                "  -pgpfp                Display PGP key fingerprints\n"
                "\n"
                "With no -e, pterm starts the user's login shell.\n"
                ) < 0 || fflush(fp) < 0) {
        perror("output error");
        exit(1);
    }
}

void putty_bridge_print_version(FILE *fp)
{
    char *buildinfo_text = buildinfo("\n");

    if (fprintf(fp, "%s: %s\n%s\n", appname, ver, buildinfo_text) < 0 ||
        fflush(fp) < 0) {
        perror("output error");
        exit(1);
    }
    sfree(buildinfo_text);
}

bool putty_conf_launchable(const PuttyConf *conf)
{
    PUTTY_BRIDGE_ASSERT_MAIN_THREAD();
    (void)conf;
    /* Local PTY sessions are always "launchable". */
    return true;
}

bool putty_conf_warn_on_close(const PuttyConf *conf)
{
    PUTTY_BRIDGE_ASSERT_MAIN_THREAD();
    if (!conf || !conf->conf)
        return true;
    return conf_get_bool(conf->conf, CONF_warn_on_close);
}
