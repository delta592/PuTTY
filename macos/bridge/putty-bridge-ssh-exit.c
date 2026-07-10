/*
 * putty-bridge-ssh-exit.c — live SSH integration test for MacGuiSeat + TermWin.
 *
 * Validates SSH login to the plan test host (default 192.168.0.19), host-key
 * dialog machinery, shell output in the terminal buffer, and clean teardown.
 */

#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "putty-bridge-internal.h"

#include "putty-bridge-thread.h"

#include "seat-dialogs.h"

static const char *ssh_exit_env_or_default(const char *name, const char *def)
{
    const char *value = getenv(name);
    return (value && *value) ? value : def;
}

static bool ssh_exit_skip_requested(void)
{
    const char *skip = getenv("PUTTY_BRIDGE_SSH_EXIT_SKIP");
    return skip && skip[0] == '1' && skip[1] == '\0';
}

static void ssh_exit_configure_hostkey(PuttyConf *conf)
{
    char hostkey[256];
    const char *configured = ssh_exit_env_or_default(
        "PUTTY_BRIDGE_TEST_HOSTKEY",
        "SHA256:QV1VZsAC792TF0SzLDcwbQ1feceWY481HUZDvbEBiaE");

    if (strlen(configured) >= sizeof(hostkey))
        return;

    strcpy(hostkey, configured);
    if (validate_manual_hostkey(hostkey))
        conf_set_str_str(conf->conf, CONF_ssh_manual_hostkeys, hostkey, "");
}

static bool ssh_exit_pump_until(
    PuttyBridgeTermWin *btw, uint64_t deadline_ms, bool *saw_output)
{
    while (putty_bridge_now_ms() < deadline_ms) {
        unsigned long now = (unsigned long)putty_bridge_now_ms();
        unsigned long next;

        run_timers(now, &next);
        putty_bridge_eventloop_pump_once();
        if (putty_toplevel_callback_pending())
            putty_run_toplevel_callbacks();

        if (putty_bridge_termwin_terminal_has_visible_text(btw)) {
            *saw_output = true;
            return true;
        }

        if (!putty_bridge_termwin_session_is_active(btw))
            return false;
    }

    return false;
}

int putty_bridge_ssh_exit_test(void)
{
    PuttyConf *conf;
    PuttyBridgeTermWin *btw;
    const char *host, *user;
    int port;
    char *endptr;
    bool saw_output = false;
    int rc = -1;

    PUTTY_BRIDGE_ASSERT_MAIN_THREAD();

    if (ssh_exit_skip_requested()) {
        fputs("PuttyBridge ssh exit test: skipped (PUTTY_BRIDGE_SSH_EXIT_SKIP=1)\n",
              stderr);
        return 0;
    }

    host = ssh_exit_env_or_default("PUTTY_BRIDGE_TEST_HOST", "192.168.0.19");
    user = ssh_exit_env_or_default("PUTTY_BRIDGE_TEST_USER", getenv("USER"));
    port = (int)strtol(
        ssh_exit_env_or_default("PUTTY_BRIDGE_TEST_PORT", "22"), &endptr, 10);
    if (!user || !*user)
        user = "root";

    mac_gui_dialogs_ensure_app();

    rc = mac_gui_seat_dialogs_smoke();
    if (rc != 0) {
        fprintf(stderr,
                "PuttyBridge ssh exit test: host-key dialog smoke failed (%d)\n",
                rc);
        return 100 + rc;
    }

    setup(false);
    putty_bridge_eventloop_start();

    setenv("PUTTY_MACOS_DIALOG_AUTO_ACCEPT", "1", 1);

    conf = putty_conf_new();
    if (!conf)
        return -1;

    putty_conf_set_protocol(conf, PUTTY_CONF_PROT_SSH);
    putty_conf_set_host(conf, host);
    putty_conf_set_port(conf, port);
    putty_conf_set_username(conf, user);
    conf_set_bool(conf->conf, CONF_tryagent, true);
    ssh_exit_configure_hostkey(conf);

    btw = putty_bridge_termwin_new();
    if (!btw) {
        putty_conf_free(conf);
        unsetenv("PUTTY_MACOS_DIALOG_AUTO_ACCEPT");
        return -2;
    }

    if (!putty_bridge_termwin_open(btw, conf, true)) {
        fprintf(stderr,
                "PuttyBridge ssh exit test: putty_bridge_termwin_open failed "
                "for %s@%s:%d\n",
                user, host, port);
        putty_bridge_termwin_free(btw);
        putty_conf_free(conf);
        unsetenv("PUTTY_MACOS_DIALOG_AUTO_ACCEPT");
        return -3;
    }

    putty_conf_free(conf);
    conf = NULL;

    if (!ssh_exit_pump_until(
            btw, putty_bridge_now_ms() + 30000, &saw_output) || !saw_output) {
        fprintf(stderr,
                "PuttyBridge ssh exit test: no shell output from %s@%s:%d "
                "(active=%d)\n",
                user, host, port,
                putty_bridge_termwin_session_is_active(btw) ? 1 : 0);
        putty_bridge_termwin_free(btw);
        unsetenv("PUTTY_MACOS_DIALOG_AUTO_ACCEPT");
        return -4;
    }

    if (!putty_bridge_termwin_session_is_active(btw)) {
        fputs("PuttyBridge ssh exit test: session not active after login\n",
              stderr);
        putty_bridge_termwin_free(btw);
        unsetenv("PUTTY_MACOS_DIALOG_AUTO_ACCEPT");
        return -5;
    }

    (void)ssh_exit_pump_until(btw, putty_bridge_now_ms() + 5000, &saw_output);

    if (!putty_bridge_termwin_should_warn_on_close(btw)) {
        fputs("PuttyBridge ssh exit test: warn-on-close not enabled\n",
              stderr);
        putty_bridge_termwin_free(btw);
        unsetenv("PUTTY_MACOS_DIALOG_AUTO_ACCEPT");
        return -7;
    }

    {
        bool warn_on_close = putty_bridge_termwin_should_warn_on_close(btw);
        bool has_specials = putty_bridge_termwin_has_specials(btw);

        putty_bridge_termwin_free(btw);
        btw = NULL;
        unsetenv("PUTTY_MACOS_DIALOG_AUTO_ACCEPT");

        fprintf(stderr,
                "PuttyBridge ssh exit test: PASS (%s@%s:%d shell output, "
                "host-key dialog smoke, warn-on-close=%d, specials=%d, "
                "clean teardown)\n",
                user, host, port, warn_on_close ? 1 : 0, has_specials ? 1 : 0);
    }
    return 0;
}
