/*
 * putty-bridge-cmdline.c — macOS GUI command-line parsing (Phase 5.5).
 */

#include <stdio.h>
#include <string.h>

#include "putty-bridge-internal.h"

#include "putty-bridge-thread.h"

#include "storage.h"

static bool putty_bridge_cmdline_extra(
    CmdlineArg *arg, CmdlineArg *nextarg, bool do_everything, Conf *conf,
    PuttyBridgeCmdlineAction *action)
{
    const char *p = cmdline_arg_to_str(arg);
    const char *val = cmdline_arg_to_str(nextarg);

    (void)val;
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
    } else {
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
        if (p[0] != '-' && (cmdline_tooltype & TOOLTYPE_HOST_ARG)) {
            /* Non-option arguments are handled by cmdline_process_param. */
            return false;
        }
        if (p[0] == '-') {
            cmdline_error("unrecognized option \"%s\"", p);
        }
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

    arglist = cmdline_arg_list_from_argv(argc, argv);
    arglistpos = 0;
    while (arglist->args[arglistpos]) {
        CmdlineArg *arg = arglist->args[arglistpos++];
        CmdlineArg *nextarg = arglist->args[arglistpos];
        int ret;

        if (putty_bridge_cmdline_extra(arg, nextarg, false, conf->conf, &action)) {
            if (action != PUTTY_BRIDGE_CMDLINE_LAUNCH) {
                putty_conf_free(conf);
                return action;
            }
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

        if (putty_bridge_cmdline_extra(arg, nextarg, true, conf->conf, &action)) {
            if (action != PUTTY_BRIDGE_CMDLINE_LAUNCH) {
                putty_conf_free(conf);
                return action;
            }
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

    if (conf_out)
        *conf_out = conf;
    else
        putty_conf_free(conf);

    if (connect_out)
        *connect_out = cmdline_host_ok(conf->conf);

    return PUTTY_BRIDGE_CMDLINE_LAUNCH;
}

void putty_bridge_print_help(FILE *fp)
{
    if (fprintf(fp,
                "PuTTY for macOS option summary:\n"
                "\n"
                "  -load SESSION     Load settings from saved session\n"
                "  [HOST]            Hostname to connect to\n"
                "  -P PORT           Port number\n"
                "  -l USER           Login name\n"
                "  -ssh -telnet ...  Connection protocol\n"
                "  -L -R -D ...      Port forwarding (see PuTTY docs)\n"
                "  --help            Display this text\n"
                "  --version         Show version and build info\n"
                "  -pgpfp            Display PGP key fingerprints\n"
                "\n"
                "If no host or -load is given, a local terminal window opens.\n"
                "The full settings editor is not yet available on macOS.\n"
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
    if (!conf || !conf->conf)
        return false;
    return conf_launchable(conf->conf);
}

bool putty_conf_warn_on_close(const PuttyConf *conf)
{
    PUTTY_BRIDGE_ASSERT_MAIN_THREAD();
    if (!conf || !conf->conf)
        return true;
    return conf_get_bool(conf->conf, CONF_warn_on_close);
}
