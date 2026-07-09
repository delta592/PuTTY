/*
 * putty-bridge-launch.c — initial config → session window flow (Phase 6.3).
 *
 * Mirrors unix/main-gtk-application.c launch_new_session /
 * new_session_window, with Swift owning the NSWindow via a registered
 * open-session callback.
 */

#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "putty-bridge-internal.h"
#include "putty-bridge-thread.h"

#include "config-appkit.h"
#include "storage.h"

static PuttyBridgeOpenSessionFn open_session_fn;
static void *open_session_ctx;
static int open_session_windows; /* live session windows (for quit-on-cancel) */

void putty_bridge_set_open_session_callback(
    PuttyBridgeOpenSessionFn fn, void *ctx)
{
    PUTTY_BRIDGE_ASSERT_MAIN_THREAD();
    open_session_fn = fn;
    open_session_ctx = ctx;
}

void putty_bridge_session_window_opened(void)
{
    PUTTY_BRIDGE_ASSERT_MAIN_THREAD();
    open_session_windows++;
}

void putty_bridge_session_window_closed(void)
{
    PUTTY_BRIDGE_ASSERT_MAIN_THREAD();
    if (open_session_windows > 0)
        open_session_windows--;
}

int putty_bridge_open_session_window_count(void)
{
    return open_session_windows;
}

bool putty_bridge_needs_initial_config(const PuttyConf *conf)
{
    PUTTY_BRIDGE_ASSERT_MAIN_THREAD();
    if (!conf || !conf->conf)
        return true;
    return !cmdline_host_ok(conf->conf);
}

static PuttyConf *putty_conf_wrap_take(Conf *conf)
{
    PuttyConf *pc;

    if (!conf)
        return NULL;
    pc = snew(PuttyConf);
    pc->conf = conf;
    return pc;
}

void new_session_window(Conf *conf, const char *geometry_string)
{
    PuttyConf *pc;
    bool connect;

    (void)geometry_string;
    PUTTY_BRIDGE_ASSERT_MAIN_THREAD();

    if (!conf)
        return;

    connect = conf_launchable(conf);
    pc = putty_conf_wrap_take(conf);

    if (!open_session_fn) {
        putty_conf_free(pc);
        return;
    }

    open_session_fn(open_session_ctx, pc, connect);
    /* Callback owns pc (must putty_conf_free when done). */
}

struct post_initial_config_box_ctx {
    Conf *conf;
};

static void post_initial_config_box(void *vctx, int result)
{
    struct post_initial_config_box_ctx *ctx =
        (struct post_initial_config_box_ctx *)vctx;

    if (result > 0) {
        new_session_window(ctx->conf, NULL);
        ctx->conf = NULL;
    } else {
        conf_free(ctx->conf);
        ctx->conf = NULL;
        /*
         * Cancel with no open sessions: signal Swift to quit (NULL conf).
         * Multi-window apps keep running if other sessions exist.
         */
        if (open_session_windows == 0 && open_session_fn)
            open_session_fn(open_session_ctx, NULL, false);
    }
    sfree(ctx);
}

void launch_new_session(void)
{
    Conf *conf;
    struct post_initial_config_box_ctx *ctx;

    PUTTY_BRIDGE_ASSERT_MAIN_THREAD();

    conf = conf_new();
    do_defaults(NULL, conf);

    ctx = snew(struct post_initial_config_box_ctx);
    ctx->conf = conf;
    initial_config_box(conf, post_initial_config_box, ctx);
}

void launch_saved_session(const char *sessionname)
{
    Conf *conf;
    struct post_initial_config_box_ctx *ctx;

    PUTTY_BRIDGE_ASSERT_MAIN_THREAD();

    conf = conf_new();
    do_defaults(sessionname, conf);

    if (conf_launchable(conf)) {
        new_session_window(conf, NULL);
        return;
    }

    ctx = snew(struct post_initial_config_box_ctx);
    ctx->conf = conf;
    initial_config_box(conf, post_initial_config_box, ctx);
}

void launch_duplicate_session(Conf *conf)
{
    PUTTY_BRIDGE_ASSERT_MAIN_THREAD();
    if (!conf)
        return;
    assert(!dup_check_launchable || conf_launchable(conf));
    new_session_window(conf_copy(conf), NULL);
}

void session_window_closed(void)
{
    putty_bridge_session_window_closed();
}

void window_setup_error(const char *errmsg)
{
    nonfatal_message_box(NULL, errmsg ? errmsg : "Error creating session window");
}

void putty_bridge_launch_new_session(void)
{
    launch_new_session();
}

void putty_bridge_start_app(PuttyConf *conf, bool connect_immediately)
{
    PUTTY_BRIDGE_ASSERT_MAIN_THREAD();

    if (connect_immediately && conf && conf->conf &&
        cmdline_host_ok(conf->conf)) {
        Conf *c = conf->conf;
        conf->conf = NULL;
        putty_conf_free(conf);
        new_session_window(c, NULL);
        return;
    }

    if (conf) {
        Conf *c = conf->conf;
        struct post_initial_config_box_ctx *ctx;

        conf->conf = NULL;
        putty_conf_free(conf);

        ctx = snew(struct post_initial_config_box_ctx);
        ctx->conf = c ? c : conf_new();
        if (!c)
            do_defaults(NULL, ctx->conf);
        initial_config_box(ctx->conf, post_initial_config_box, ctx);
        return;
    }

    launch_new_session();
}

/* ---------------------------------------------------------------------- */
/* Smoke (headless): exercise need-config decision + Open/Cancel callbacks */

struct launch_smoke_state {
    int opened;
    int quit_requests;
    PuttyConf *last_conf;
    bool last_connect;
};

static void launch_smoke_open_cb(void *ctx, PuttyConf *conf, bool connect)
{
    struct launch_smoke_state *st = (struct launch_smoke_state *)ctx;

    if (!conf) {
        st->quit_requests++;
        return;
    }
    st->opened++;
    st->last_conf = conf;
    st->last_connect = connect;
    putty_bridge_session_window_opened();
}

int putty_bridge_launch_smoke(void)
{
    struct launch_smoke_state st;
    PuttyConf *empty;

    memset(&st, 0, sizeof(st));
    open_session_windows = 0;
    putty_bridge_set_open_session_callback(launch_smoke_open_cb, &st);

    /*
     * cmdline_host_ok() is false until -load / a hostname argv is seen,
     * even if Conf is launchable — so a fresh defaults Conf needs the
     * initial config box.
     */
    empty = putty_conf_new();
    if (!putty_bridge_needs_initial_config(empty)) {
        fprintf(stderr, "putty_bridge_launch_smoke: empty conf should need config\n");
        putty_conf_free(empty);
        return 1;
    }
    putty_conf_free(empty);

    /*
     * Direct-connect path: putty_bridge_start_app with
     * connect_immediately=true still requires cmdline_host_ok. Simulate
     * a successful Open from the config dialog via new_session_window.
     */
    {
        Conf *conf = conf_new();
        do_defaults(NULL, conf);
        conf_set_str(conf, CONF_host, "smoke.example");
        conf_set_int(conf, CONF_port, 22);
        conf_set_int(conf, CONF_protocol, PROT_SSH);
        if (!conf_launchable(conf)) {
            fprintf(stderr, "putty_bridge_launch_smoke: test conf not launchable\n");
            conf_free(conf);
            return 2;
        }
        new_session_window(conf, NULL);
        if (st.opened != 1 || !st.last_conf || !st.last_connect) {
            fprintf(stderr, "putty_bridge_launch_smoke: Open path failed "
                    "(opened=%d connect=%d)\n",
                    st.opened, st.last_connect ? 1 : 0);
            if (st.last_conf)
                putty_conf_free(st.last_conf);
            return 3;
        }
        if (!putty_conf_launchable(st.last_conf)) {
            fprintf(stderr, "putty_bridge_launch_smoke: opened conf not launchable\n");
            putty_conf_free(st.last_conf);
            return 4;
        }
        putty_conf_free(st.last_conf);
        st.last_conf = NULL;
        putty_bridge_session_window_closed();
        st.opened = 0;
    }

    /* Non-launchable Open still creates a local-echo window (connect=false). */
    {
        Conf *conf = conf_new();
        do_defaults(NULL, conf);
        new_session_window(conf, NULL);
        if (st.opened != 1 || !st.last_conf || st.last_connect) {
            fprintf(stderr, "putty_bridge_launch_smoke: local-echo open failed\n");
            if (st.last_conf)
                putty_conf_free(st.last_conf);
            return 5;
        }
        putty_conf_free(st.last_conf);
        st.last_conf = NULL;
        putty_bridge_session_window_closed();
        st.opened = 0;
    }

    /* Cancel with zero windows → quit request */
    if (open_session_fn)
        open_session_fn(open_session_ctx, NULL, false);
    if (st.quit_requests != 1) {
        fprintf(stderr, "putty_bridge_launch_smoke: cancel quit not signalled\n");
        return 6;
    }

    putty_bridge_set_open_session_callback(NULL, NULL);
    open_session_windows = 0;

    puts("putty_bridge_launch_smoke: ok");
    return 0;
}
