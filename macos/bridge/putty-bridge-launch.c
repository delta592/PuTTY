/*
 * putty-bridge-launch.c — initial config → session window flow (Phase 6.3).
 *
 * Mirrors unix/main-gtk-application.c launch_new_session /
 * new_session_window, with Swift owning the NSWindow via a registered
 * open-session callback.
 */

#include <assert.h>
#include <ctype.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "putty-bridge-internal.h"
#include "putty-bridge-thread.h"

#include "config-appkit.h"
#include "platform.h"
#include "seat.h"
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
    if ((cmdline_tooltype & TOOLTYPE_NONNETWORK) != 0)
        return false;
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

    /*
     * Network apps require a host (conf_launchable). pterm-style apps
     * (TOOLTYPE_NONNETWORK) always start the PTY backend immediately,
     * matching unix/main-gtk-simple.c.
     */
    connect = conf_launchable(conf) ||
              (cmdline_tooltype & TOOLTYPE_NONNETWORK) != 0;
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

void putty_bridge_launch_saved_session(const char *session_name)
{
    PUTTY_BRIDGE_ASSERT_MAIN_THREAD();
    if (!session_name || !session_name[0])
        return;
    launch_saved_session(session_name);
}

size_t putty_bridge_copy_saved_session_names(char **out, size_t max_out)
{
    struct sesslist sesslist;
    size_t written = 0;
    int i;

    PUTTY_BRIDGE_ASSERT_MAIN_THREAD();
    if (!out || max_out == 0)
        return 0;

    get_sesslist(&sesslist, true);
    /* Skip sessions[0] == "Default Settings" (GTK/Windows parity). */
    for (i = 1; i < sesslist.nsessions && written < max_out; i++) {
        if (!sesslist.sessions[i] || !sesslist.sessions[i][0])
            continue;
        out[written++] = dupstr(sesslist.sessions[i]);
    }
    get_sesslist(&sesslist, false);
    return written;
}

void putty_bridge_free_string(char *s)
{
    sfree(s);
}

void putty_bridge_cleanup_all(void)
{
    PUTTY_BRIDGE_ASSERT_MAIN_THREAD();
    cleanup_all();
}

static bool putty_bridge_url_percent_decode(char *s)
{
    char *src = s, *dst = s;

    if (!s)
        return false;
    while (*src) {
        if (src[0] == '%' &&
            isxdigit((unsigned char)src[1]) &&
            isxdigit((unsigned char)src[2])) {
            unsigned int hi = src[1];
            unsigned int lo = src[2];
            hi = (hi >= 'a') ? hi - 'a' + 10 :
                 (hi >= 'A') ? hi - 'A' + 10 : hi - '0';
            lo = (lo >= 'a') ? lo - 'a' + 10 :
                 (lo >= 'A') ? lo - 'A' + 10 : lo - '0';
            *dst++ = (char)((hi << 4) | lo);
            src += 3;
        } else if (src[0] == '+') {
            *dst++ = ' ';
            src++;
        } else {
            *dst++ = *src++;
        }
    }
    *dst = '\0';
    return true;
}

bool putty_bridge_conf_from_url(PuttyConf *conf, const char *url)
{
    char *work = NULL;
    char *scheme;
    char *rest;
    bool ok = false;

    PUTTY_BRIDGE_ASSERT_MAIN_THREAD();
    if (!conf || !conf->conf || !url || !url[0])
        return false;

    work = dupstr(url);
    scheme = work;
    rest = strstr(work, "://");
    if (!rest) {
        sfree(work);
        return false;
    }
    *rest = '\0';
    rest += 3;

    if (!strcmp(scheme, "ssh") || !strcmp(scheme, "telnet") ||
        !strcmp(scheme, "rlogin") || !strcmp(scheme, "supdup")) {
        char *user = NULL;
        char *host;
        char *portstr = NULL;
        char *at;
        char *colon;
        char *slash;
        int protocol = PROT_SSH;
        int port;

        if (!strcmp(scheme, "telnet"))
            protocol = PROT_TELNET;
        else if (!strcmp(scheme, "rlogin"))
            protocol = PROT_RLOGIN;
        else if (!strcmp(scheme, "supdup"))
            protocol = PROT_SUPDUP;

        slash = strchr(rest, '/');
        if (slash)
            *slash = '\0';

        at = strrchr(rest, '@');
        if (at) {
            *at = '\0';
            user = rest;
            host = at + 1;
        } else {
            host = rest;
        }

        /* IPv6 in brackets: [2001:db8::1]:22 */
        if (host[0] == '[') {
            char *end = strchr(host, ']');
            if (!end) {
                sfree(work);
                return false;
            }
            *end = '\0';
            host++;
            if (end[1] == ':')
                portstr = end + 2;
        } else {
            colon = strrchr(host, ':');
            if (colon) {
                *colon = '\0';
                portstr = colon + 1;
            }
        }

        putty_bridge_url_percent_decode(host);
        if (user)
            putty_bridge_url_percent_decode(user);

        if (!host[0]) {
            sfree(work);
            return false;
        }

        do_defaults(NULL, conf->conf);
        conf_set_int(conf->conf, CONF_protocol, protocol);
        conf_set_str(conf->conf, CONF_host, host);
        if (user && user[0])
            conf_set_str(conf->conf, CONF_username, user);
        port = portstr && portstr[0] ? atoi(portstr)
                                     : putty_conf_default_port_for_protocol(protocol);
        if (port > 0)
            conf_set_int(conf->conf, CONF_port, port);
        ok = true;
    } else if (!strcmp(scheme, "putty")) {
        char *path = rest;
        char *session;

        /* putty://load/Name or putty://Name */
        if (!strncmp(path, "load/", 5))
            session = path + 5;
        else
            session = path;

        /* Drop trailing slash */
        {
            size_t n = strlen(session);
            while (n > 0 && session[n - 1] == '/') {
                session[n - 1] = '\0';
                n--;
            }
        }
        putty_bridge_url_percent_decode(session);
        if (!session[0]) {
            sfree(work);
            return false;
        }
        do_defaults(session, conf->conf);
        ok = true;
    }

    sfree(work);
    return ok;
}

void putty_bridge_show_host_ca_config(void)
{
    PUTTY_BRIDGE_ASSERT_MAIN_THREAD();
    show_ca_config_box_synchronously();
}

void putty_bridge_start_app(PuttyConf *conf, bool connect_immediately)
{
    PUTTY_BRIDGE_ASSERT_MAIN_THREAD();

    /*
     * pterm (TOOLTYPE_NONNETWORK): always open immediately — never call
     * cmdline_host_ok() (it asserts TOOLTYPE_HOST_ARG).
     */
    if ((cmdline_tooltype & TOOLTYPE_NONNETWORK) != 0) {
        Conf *c;

        if (!conf) {
            launch_new_session();
            return;
        }
        c = conf->conf;
        conf->conf = NULL;
        putty_conf_free(conf);
        if (!c) {
            c = conf_new();
            do_defaults(NULL, c);
        }
        conf_set_int(c, CONF_protocol, -1);
        new_session_window(c, NULL);
        return;
    }

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

    /* Phase 7.1: launch_duplicate_session copies Conf into a new window. */
    {
        Conf *conf = conf_new();
        do_defaults(NULL, conf);
        conf_set_str(conf, CONF_host, "dup.example");
        conf_set_int(conf, CONF_port, 22);
        conf_set_int(conf, CONF_protocol, PROT_SSH);
        st.opened = 0;
        st.last_conf = NULL;
        launch_duplicate_session(conf);
        conf_free(conf);
        if (st.opened != 1 || !st.last_conf || !st.last_connect) {
            fprintf(stderr, "putty_bridge_launch_smoke: duplicate failed\n");
            if (st.last_conf)
                putty_conf_free(st.last_conf);
            return 7;
        }
        if (strcmp(putty_conf_get_host(st.last_conf), "dup.example") != 0) {
            fprintf(stderr, "putty_bridge_launch_smoke: duplicate host mismatch\n");
            putty_conf_free(st.last_conf);
            return 8;
        }
        putty_conf_free(st.last_conf);
        st.last_conf = NULL;
        putty_bridge_session_window_closed();
        st.opened = 0;
    }

    /* Phase 7.1: URL → Conf (ssh://). */
    {
        PuttyConf *pc = putty_conf_new();
        PuttyConf *bad;

        if (!putty_bridge_conf_from_url(pc, "ssh://alice@example.com:2222")) {
            fprintf(stderr, "putty_bridge_launch_smoke: ssh URL parse failed\n");
            putty_conf_free(pc);
            return 9;
        }
        if (strcmp(putty_conf_get_host(pc), "example.com") != 0 ||
            putty_conf_get_port(pc) != 2222 ||
            strcmp(putty_conf_get_username(pc), "alice") != 0 ||
            putty_conf_get_protocol(pc) != PROT_SSH) {
            fprintf(stderr, "putty_bridge_launch_smoke: ssh URL fields wrong\n");
            putty_conf_free(pc);
            return 10;
        }
        putty_conf_free(pc);

        pc = putty_conf_new();
        if (!putty_bridge_conf_from_url(pc, "ssh://[2001:db8::1]:22")) {
            fprintf(stderr, "putty_bridge_launch_smoke: ssh IPv6 URL failed\n");
            putty_conf_free(pc);
            return 11;
        }
        if (strcmp(putty_conf_get_host(pc), "2001:db8::1") != 0 ||
            putty_conf_get_port(pc) != 22) {
            fprintf(stderr, "putty_bridge_launch_smoke: ssh IPv6 fields wrong\n");
            putty_conf_free(pc);
            return 12;
        }
        putty_conf_free(pc);

        bad = putty_conf_new();
        if (putty_bridge_conf_from_url(bad, "ftp://example.com") ||
            putty_bridge_conf_from_url(bad, "not-a-url") ||
            putty_bridge_conf_from_url(NULL, "ssh://x")) {
            fprintf(stderr, "putty_bridge_launch_smoke: bad URL should fail\n");
            putty_conf_free(bad);
            return 13;
        }
        putty_conf_free(bad);
    }

    /* Phase 7.1: can_restart / restart after simulated remote exit. */
    {
        MacGuiSeat *seat;
        Conf *conf = conf_new();

        do_defaults(NULL, conf);
        conf_set_str(conf, CONF_host, "restart.example");
        conf_set_int(conf, CONF_port, 22);
        conf_set_int(conf, CONF_protocol, PROT_SSH);

        seat = mac_gui_seat_new(conf);
        conf_free(conf);
        if (!seat) {
            fprintf(stderr, "putty_bridge_launch_smoke: seat new failed\n");
            return 14;
        }
        if (!mac_gui_seat_start_local_echo(seat)) {
            fprintf(stderr, "putty_bridge_launch_smoke: local echo start failed\n");
            mac_gui_seat_free(seat);
            return 15;
        }
        if (mac_gui_seat_can_restart(seat)) {
            fprintf(stderr, "putty_bridge_launch_smoke: can_restart while live\n");
            mac_gui_seat_free(seat);
            return 16;
        }
        mac_gui_seat_destroy_connection(seat);
        if (!mac_gui_seat_can_restart(seat)) {
            fprintf(stderr, "putty_bridge_launch_smoke: can_restart after exit\n");
            mac_gui_seat_free(seat);
            return 17;
        }
        /*
         * Restart would call select_backend + backend_init for SSH; that
         * needs a real host. Verify the gate only — start is covered by
         * seat smokes. Clear exited without network by freeing.
         */
        mac_gui_seat_free(seat);
    }

    /* Phase 7.1: saved-session name enumeration is callable. */
    {
        char *names[8];
        size_t n = putty_bridge_copy_saved_session_names(names, 8);
        size_t i;
        for (i = 0; i < n; i++)
            putty_bridge_free_string(names[i]);
        (void)n;
    }

    putty_bridge_set_open_session_callback(NULL, NULL);
    open_session_windows = 0;

    puts("putty_bridge_launch_smoke: ok");
    return 0;
}
