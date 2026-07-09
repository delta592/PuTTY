/*
 * putty-bridge-internal.h — bridge implementation details (not Swift-visible).
 */

#ifndef PUTTY_MACOS_PUTTY_BRIDGE_INTERNAL_H
#define PUTTY_MACOS_PUTTY_BRIDGE_INTERNAL_H

#include "putty.h"

#include "putty-bridge.h"

struct PuttyConf {
    Conf *conf;
};

struct PuttySession {
    Seat seat;
    TermWin termwin;
    LogPolicy logpolicy;

    Conf *conf;
    Terminal *term;
    Ldisc *ldisc;
    Backend *backend;
    LogContext *logctx;
    struct unicode_data ucsdata;

    bool started;
    bool exited;
    cmdline_get_passwd_input_state cmdline_get_passwd_state;

    PuttySessionCallbacks callbacks;
    void *callback_ctx;
};

Conf *putty_bridge_conf_copy(const PuttyConf *conf);

#endif /* PUTTY_MACOS_PUTTY_BRIDGE_INTERNAL_H */
