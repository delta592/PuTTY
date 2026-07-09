/*
 * pterm-smoke.c — Phase 7.2 headless checks for pterm bridge constants.
 */

#include <stdio.h>
#include <string.h>

#include "putty-bridge.h"
#include "putty-bridge-internal.h"
#include "putty-bridge-thread.h"

#include "platform.h"

struct pterm_smoke_state {
    int opened;
    int quit_requests;
    PuttyConf *last_conf;
    bool last_connect;
};

static void pterm_smoke_open_cb(void *ctx, PuttyConf *conf, bool connect)
{
    struct pterm_smoke_state *st = (struct pterm_smoke_state *)ctx;

    if (!conf) {
        st->quit_requests++;
        return;
    }
    st->opened++;
    st->last_conf = conf;
    st->last_connect = connect;
    putty_bridge_session_window_opened();
}

int putty_mac_pterm_smoke(void)
{
    struct pterm_smoke_state st;
    PuttyConf *conf;

    memset(&st, 0, sizeof(st));

    if (!use_pty_argv) {
        fprintf(stderr, "putty_mac_pterm_smoke: use_pty_argv should be true\n");
        return 1;
    }
    if (new_session || saved_sessions || use_event_log) {
        fprintf(stderr, "putty_mac_pterm_smoke: pterm menu flags wrong\n");
        return 2;
    }
    if (!(cmdline_tooltype & TOOLTYPE_NONNETWORK)) {
        fprintf(stderr, "putty_mac_pterm_smoke: expected TOOLTYPE_NONNETWORK\n");
        return 3;
    }
    if (select_backend(NULL) != &pty_backend) {
        fprintf(stderr, "putty_mac_pterm_smoke: select_backend != pty_backend\n");
        return 4;
    }

    putty_bridge_set_open_session_callback(pterm_smoke_open_cb, &st);

    conf = putty_conf_new();
    conf_set_int(conf->conf, CONF_protocol, -1);
    putty_bridge_start_app(conf, true);

    if (st.opened != 1 || !st.last_conf || !st.last_connect) {
        fprintf(stderr, "putty_mac_pterm_smoke: immediate open failed "
                "(opened=%d connect=%d)\n",
                st.opened, st.last_connect ? 1 : 0);
        if (st.last_conf)
            putty_conf_free(st.last_conf);
        return 5;
    }
    if (putty_conf_get_protocol(st.last_conf) != -1) {
        fprintf(stderr, "putty_mac_pterm_smoke: protocol should be -1\n");
        putty_conf_free(st.last_conf);
        return 6;
    }

    putty_conf_free(st.last_conf);
    putty_bridge_session_window_closed();
    putty_bridge_set_open_session_callback(NULL, NULL);

    puts("putty_mac_pterm_smoke: ok");
    return 0;
}
