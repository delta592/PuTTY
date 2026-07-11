/*
 * putty-bridge-cmdline.c — macOS GUI command-line parsing (Phase 5.5).
 *
 * Bridge-internal: unwraps PuttyConf→Conf* for upstream cmdline_process_param /
 * cmdline_run_saved / conf_launchable. Do not expose Conf* to Swift; new
 * settings for UI/tests go through putty_conf_* in putty-conf.c.
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
        if (!strcmp(p, "-cleanup")) {
            *action = PUTTY_BRIDGE_CMDLINE_CLEANUP;
            return true;
        }
        if (has_ca_config_box &&
            (!strcmp(p, "-host-ca") || !strcmp(p, "-host_ca") ||
             !strcmp(p, "--host-ca") || !strcmp(p, "--host_ca"))) {
            *action = PUTTY_BRIDGE_CMDLINE_HOST_CA;
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
        if (!strcmp(p, "-cleanup")) {
            *action = PUTTY_BRIDGE_CMDLINE_CLEANUP;
            return true;
        }
        if (has_ca_config_box &&
            (!strcmp(p, "-host-ca") || !strcmp(p, "-host_ca") ||
             !strcmp(p, "--host-ca") || !strcmp(p, "--host_ca"))) {
            *action = PUTTY_BRIDGE_CMDLINE_HOST_CA;
            return true;
        }
        /*
         * Other options (and bare hostnames) are handled by
         * cmdline_process_param in the caller. Do not treat unknown
         * dashes as fatal here — that blocked -P/-l/-ssh/-load.
         */
        return false;
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
                "  -cleanup          Delete saved sessions and other PuTTY data\n"
                "  -host-ca          Configure trusted SSH host CAs\n"
                "\n"
                "If no host or -load is given, the configuration dialog opens.\n"
                "URL schemes ssh:// and putty:// are also accepted when opened\n"
                "from the Finder or `open` (see Info.plist).\n"
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

int putty_bridge_cmdline_smoke(void)
{
    PuttyConf *conf = NULL;
    bool connect = false;
    PuttyBridgeCmdlineAction action;
    char *argv_help[] = { "putty", "--help", NULL };
    char *argv_version[] = { "putty", "--version", NULL };
    char *argv_pgpfp[] = { "putty", "-pgpfp", NULL };
    char *argv_hostca[] = { "putty", "-host-ca", NULL };
    char *argv_cleanup[] = { "putty", "-cleanup", NULL };
    char *argv_host[] = {
        "putty", "bridge-cmdline.example", "-P", "2222", "-l", "smoke",
        "-ssh", NULL
    };
    FILE *nullout;
    int rc = 0;

    PUTTY_BRIDGE_ASSERT_MAIN_THREAD();

    nullout = fopen("/dev/null", "w");
    if (!nullout)
        nullout = stderr;

    action = putty_bridge_process_command_line(
        2, argv_help, &conf, &connect);
    if (action != PUTTY_BRIDGE_CMDLINE_EXIT_HELP || conf) {
        rc = -1;
        goto out;
    }
    putty_bridge_print_help(nullout);

    action = putty_bridge_process_command_line(
        2, argv_version, &conf, &connect);
    if (action != PUTTY_BRIDGE_CMDLINE_EXIT_VERSION || conf) {
        rc = -2;
        goto out;
    }
    putty_bridge_print_version(nullout);

    action = putty_bridge_process_command_line(
        2, argv_pgpfp, &conf, &connect);
    if (action != PUTTY_BRIDGE_CMDLINE_EXIT_OK || conf) {
        rc = -3;
        goto out;
    }

    action = putty_bridge_process_command_line(
        2, argv_hostca, &conf, &connect);
    if (action != PUTTY_BRIDGE_CMDLINE_HOST_CA || conf) {
        rc = -4;
        goto out;
    }

    action = putty_bridge_process_command_line(
        2, argv_cleanup, &conf, &connect);
    if (action != PUTTY_BRIDGE_CMDLINE_CLEANUP || conf) {
        rc = -5;
        goto out;
    }

    action = putty_bridge_process_command_line(
        7, argv_host, &conf, &connect);
    if (action != PUTTY_BRIDGE_CMDLINE_LAUNCH || !conf) {
        rc = -6;
        goto out;
    }
    if (!connect) {
        rc = -7;
        goto out;
    }
    if (strcmp(putty_conf_get_host(conf), "bridge-cmdline.example") != 0) {
        rc = -8;
        goto out;
    }
    if (putty_conf_get_port(conf) != 2222) {
        rc = -9;
        goto out;
    }
    if (strcmp(putty_conf_get_username(conf), "smoke") != 0) {
        rc = -10;
        goto out;
    }
    if (putty_conf_get_protocol(conf) != PUTTY_CONF_PROT_SSH) {
        rc = -11;
        goto out;
    }
    if (!putty_conf_launchable(conf)) {
        rc = -12;
        goto out;
    }
    putty_conf_free(conf);
    conf = NULL;

    {
        char *argv_more[] = {
            "putty", "-telnet", "telnet.example", "-P", "23",
            "-4", "-C", NULL
        };
        action = putty_bridge_process_command_line(
            7, argv_more, &conf, &connect);
        if (action != PUTTY_BRIDGE_CMDLINE_LAUNCH || !conf) {
            rc = -13;
            goto out;
        }
        if (putty_conf_get_protocol(conf) != PUTTY_CONF_PROT_TELNET) {
            rc = -14;
            goto out;
        }
        putty_conf_free(conf);
        conf = NULL;
    }

    {
        char *argv_raw[] = { "putty", "-raw", "raw.example", NULL };
        action = putty_bridge_process_command_line(
            3, argv_raw, &conf, &connect);
        if (action != PUTTY_BRIDGE_CMDLINE_LAUNCH || !conf) {
            rc = -15;
            goto out;
        }
        if (putty_conf_get_protocol(conf) != PUTTY_CONF_PROT_RAW) {
            rc = -16;
            goto out;
        }
        putty_conf_free(conf);
        conf = NULL;
    }

    {
        char *argv_ssh2[] = {
            "putty", "-ssh", "-2", "ssh2.example", "-P", "22",
            "-l", "u", "-N", "-A", "-a", "-X", "-x", "-t", "-T",
            NULL
        };
        action = putty_bridge_process_command_line(
            15, argv_ssh2, &conf, &connect);
        if (action != PUTTY_BRIDGE_CMDLINE_LAUNCH || !conf) {
            rc = -17;
            goto out;
        }
        if (putty_conf_get_protocol(conf) != PUTTY_CONF_PROT_SSH) {
            rc = -18;
            goto out;
        }
        putty_conf_free(conf);
        conf = NULL;
    }

    {
        char *argv_rlogin[] = {
            "putty", "-rlogin", "rlogin.example", NULL
        };
        action = putty_bridge_process_command_line(
            3, argv_rlogin, &conf, &connect);
        if (action != PUTTY_BRIDGE_CMDLINE_LAUNCH || !conf) {
            rc = -19;
            goto out;
        }
        if (putty_conf_get_protocol(conf) != PUTTY_CONF_PROT_RLOGIN) {
            rc = -20;
            goto out;
        }
        putty_conf_free(conf);
        conf = NULL;
    }

  out:
    if (conf)
        putty_conf_free(conf);
    if (nullout != stderr)
        fclose(nullout);
    return rc;
}

bool putty_conf_warn_on_close(const PuttyConf *conf)
{
    PUTTY_BRIDGE_ASSERT_MAIN_THREAD();
    if (!conf || !conf->conf)
        return true;
    return conf_get_bool(conf->conf, CONF_warn_on_close);
}
