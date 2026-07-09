/*
 * putty-bridge-phase3-exit.c — Phase 3 exit-criteria integration test.
 *
 * Creates a PuttySession, starts SSH to a test host, pumps the bridge event
 * loop, and verifies server output bytes arrive via on_output callback.
 */

#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "putty-bridge-internal.h"

#include "putty-bridge-thread.h"

struct phase3_exit_ctx {
    size_t output_bytes;
    bool exited;
};

static const char *phase3_env_or_default(const char *name, const char *def)
{
    const char *value = getenv(name);
    return (value && *value) ? value : def;
}

static void phase3_on_output(void *ctx, const void *data, size_t len)
{
    struct phase3_exit_ctx *test = (struct phase3_exit_ctx *)ctx;

    test->output_bytes += len;
}

static void phase3_on_exit(void *ctx)
{
    struct phase3_exit_ctx *test = (struct phase3_exit_ctx *)ctx;
    test->exited = true;
}

static bool phase3_skip_requested(void)
{
    const char *skip = getenv("PUTTY_BRIDGE_PHASE3_SKIP");
    return skip && skip[0] == '1' && skip[1] == '\0';
}

static void phase3_configure_hostkey(PuttyConf *conf)
{
    char hostkey[256];
    const char *configured = phase3_env_or_default(
        "PUTTY_BRIDGE_TEST_HOSTKEY",
        "SHA256:QV1VZsAC792TF0SzLDcwbQ1feceWY481HUZDvbEBiaE");

    if (strlen(configured) >= sizeof(hostkey))
        return;

    strcpy(hostkey, configured);
    if (validate_manual_hostkey(hostkey))
        conf_set_str_str(conf->conf, CONF_ssh_manual_hostkeys, hostkey, "");
}

int putty_bridge_phase3_exit_test(void)
{
    struct phase3_exit_ctx test_ctx;
    PuttySessionCallbacks callbacks;
    PuttyConf *conf;
    PuttySession *session;
    PuttyPollWrapper *poll;
    const char *host, *user;
    int port;
    char *endptr;
    uint64_t deadline_ms;
    int result = -1;

    PUTTY_BRIDGE_ASSERT_MAIN_THREAD();

    if (phase3_skip_requested()) {
        fputs("PuttyBridge phase3 exit test: skipped (PUTTY_BRIDGE_PHASE3_SKIP=1)\n",
              stderr);
        return 0;
    }

    host = phase3_env_or_default("PUTTY_BRIDGE_TEST_HOST", "127.0.0.1");
    user = phase3_env_or_default("PUTTY_BRIDGE_TEST_USER", getenv("USER"));
    port = (int)strtol(
        phase3_env_or_default("PUTTY_BRIDGE_TEST_PORT", "22"), &endptr, 10);
    if (!user || !*user)
        user = "root";

    memset(&test_ctx, 0, sizeof(test_ctx));
    memset(&callbacks, 0, sizeof(callbacks));
    callbacks.on_output = phase3_on_output;
    callbacks.on_exit = phase3_on_exit;

    setup(false);

    conf = putty_conf_new();
    if (!conf)
        return -1;

    putty_bridge_eventloop_init();

    putty_conf_set_protocol(conf, PUTTY_CONF_PROT_SSH);
    putty_conf_set_host(conf, host);
    putty_conf_set_port(conf, port);
    putty_conf_set_username(conf, user);
    conf_set_bool(conf->conf, CONF_tryagent, true);
    phase3_configure_hostkey(conf);

    session = putty_session_new(conf);
    if (!session) {
        putty_conf_free(conf);
        return -2;
    }

    putty_session_set_callbacks(session, &callbacks, &test_ctx);
    putty_session_start(session);

    poll = putty_pollwrapper_new();
    if (!poll) {
        putty_session_free(session);
        putty_conf_free(conf);
        return -3;
    }

    deadline_ms = putty_bridge_now_ms() + 15000;
    while (putty_bridge_now_ms() < deadline_ms &&
           test_ctx.output_bytes == 0 &&
           !test_ctx.exited) {
        uint64_t now = putty_bridge_now_ms();

        putty_run_timers(now);
        putty_uxsel_fill_pollfds(poll);
        putty_pollwrapper_poll_timeout(poll, 100);
        putty_pollwrapper_process_events(poll);
        if (putty_toplevel_callback_pending())
            putty_run_toplevel_callbacks();
    }

    if (test_ctx.output_bytes > 0)
        result = 0;
    else
        result = -4;

    putty_pollwrapper_free(poll);
    putty_session_free(session);
    putty_conf_free(conf);

    if (result == 0) {
        fprintf(stderr,
                "PuttyBridge phase3 exit test: PASS (%zu output bytes from %s@%s:%d)\n",
                test_ctx.output_bytes, user, host, port);
    } else {
        fprintf(stderr,
                "PuttyBridge phase3 exit test: FAIL (no output from %s@%s:%d)\n",
                user, host, port);
    }

    return result;
}
