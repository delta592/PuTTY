/*
 * putty-conf.c — PuttyConf configuration wrappers (Phase 3.3).
 */

#include <string.h>

#include "putty-bridge-internal.h"

#include "putty-bridge-thread.h"

#include "storage.h"

PuttyConf *putty_conf_new(void)
{
    PUTTY_BRIDGE_ASSERT_MAIN_THREAD();
    PuttyConf *pc = snew(PuttyConf);

    pc->conf = conf_new();
    do_defaults(NULL, pc->conf);
    return pc;
}

PuttyConf *putty_conf_copy(const PuttyConf *conf)
{
    PUTTY_BRIDGE_ASSERT_MAIN_THREAD();
    PuttyConf *copy;

    if (!conf || !conf->conf)
        return NULL;

    copy = snew(PuttyConf);
    copy->conf = conf_copy(conf->conf);
    return copy;
}

void putty_conf_free(PuttyConf *conf)
{
    PUTTY_BRIDGE_ASSERT_MAIN_THREAD();
    if (!conf)
        return;
    if (conf->conf)
        conf_free(conf->conf);
    sfree(conf);
}

bool putty_conf_load_session(PuttyConf *conf, const char *session_name)
{
    PUTTY_BRIDGE_ASSERT_MAIN_THREAD();
    if (!conf || !conf->conf)
        return false;
    if (!session_name)
        session_name = "Default Settings";
    return load_settings(session_name, conf->conf);
}

bool putty_conf_save_session(PuttyConf *conf, const char *session_name)
{
    PUTTY_BRIDGE_ASSERT_MAIN_THREAD();
    char *errmsg;

    if (!conf || !conf->conf || !session_name)
        return false;

    errmsg = save_settings(session_name, conf->conf);
    if (errmsg) {
        sfree(errmsg);
        return false;
    }
    return true;
}

Conf *putty_bridge_conf_copy(const PuttyConf *conf)
{
    if (!conf || !conf->conf)
        return NULL;
    return conf_copy(conf->conf);
}

const char *putty_conf_get_host(const PuttyConf *conf)
{
    PUTTY_BRIDGE_ASSERT_MAIN_THREAD();
    if (!conf || !conf->conf)
        return "";
    return conf_get_str(conf->conf, CONF_host);
}

void putty_conf_set_host(PuttyConf *conf, const char *host)
{
    PUTTY_BRIDGE_ASSERT_MAIN_THREAD();
    if (!conf || !conf->conf)
        return;
    conf_set_str(conf->conf, CONF_host, host ? host : "");
}

const char *putty_conf_get_username(const PuttyConf *conf)
{
    PUTTY_BRIDGE_ASSERT_MAIN_THREAD();
    if (!conf || !conf->conf)
        return "";
    return conf_get_str_ambi(conf->conf, CONF_username, NULL);
}

void putty_conf_set_username(PuttyConf *conf, const char *username)
{
    PUTTY_BRIDGE_ASSERT_MAIN_THREAD();
    if (!conf || !conf->conf)
        return;
    conf_set_str(conf->conf, CONF_username, username ? username : "");
}

int putty_conf_get_port(const PuttyConf *conf)
{
    PUTTY_BRIDGE_ASSERT_MAIN_THREAD();
    if (!conf || !conf->conf)
        return 0;
    return conf_get_int(conf->conf, CONF_port);
}

void putty_conf_set_port(PuttyConf *conf, int port)
{
    PUTTY_BRIDGE_ASSERT_MAIN_THREAD();
    if (!conf || !conf->conf)
        return;
    conf_set_int(conf->conf, CONF_port, port);
}

int putty_conf_get_protocol(const PuttyConf *conf)
{
    PUTTY_BRIDGE_ASSERT_MAIN_THREAD();
    if (!conf || !conf->conf)
        return PUTTY_CONF_PROT_SSH;
    return conf_get_int(conf->conf, CONF_protocol);
}

int putty_conf_default_port_for_protocol(int protocol)
{
    PUTTY_BRIDGE_ASSERT_MAIN_THREAD();
    switch (protocol) {
      case PUTTY_CONF_PROT_TELNET:
        return 23;
      case PUTTY_CONF_PROT_RLOGIN:
        return 513;
      case PUTTY_CONF_PROT_SSH:
      case PUTTY_CONF_PROT_SSHCONN:
        return 22;
      case PUTTY_CONF_PROT_SUPDUP:
        return 95;
      case PUTTY_CONF_PROT_RAW:
      case PUTTY_CONF_PROT_SERIAL:
      default:
        return 0;
    }
}

void putty_conf_set_protocol(PuttyConf *conf, int protocol)
{
    PUTTY_BRIDGE_ASSERT_MAIN_THREAD();
    if (!conf || !conf->conf)
        return;
    conf_set_int(conf->conf, CONF_protocol, protocol);
}

bool putty_conf_get_bool(const PuttyConf *conf, PuttyConfBoolKey key)
{
    PUTTY_BRIDGE_ASSERT_MAIN_THREAD();
    if (!conf || !conf->conf)
        return false;

    switch (key) {
      case PUTTY_CONF_BOOL_TCP_NODELAY:
        return conf_get_bool(conf->conf, CONF_tcp_nodelay);
      case PUTTY_CONF_BOOL_TCP_KEEPALIVES:
        return conf_get_bool(conf->conf, CONF_tcp_keepalives);
      default:
        return false;
    }
}

void putty_conf_set_bool(PuttyConf *conf, PuttyConfBoolKey key, bool value)
{
    PUTTY_BRIDGE_ASSERT_MAIN_THREAD();
    if (!conf || !conf->conf)
        return;

    switch (key) {
      case PUTTY_CONF_BOOL_TCP_NODELAY:
        conf_set_bool(conf->conf, CONF_tcp_nodelay, value);
        break;
      case PUTTY_CONF_BOOL_TCP_KEEPALIVES:
        conf_set_bool(conf->conf, CONF_tcp_keepalives, value);
        break;
      default:
        break;
    }
}

static const char *const putty_conf_smoke_session = "__PuttyBridgeConfSmoke__";

int putty_bridge_conf_smoke(void)
{
    PUTTY_BRIDGE_ASSERT_MAIN_THREAD();
    PuttyConf *conf, *loaded;
    const char *host;

    conf = putty_conf_new();
    if (!conf)
        return -1;

    putty_conf_set_host(conf, "bridge-smoke.example");
    putty_conf_set_port(conf, 2222);
    putty_conf_set_protocol(conf, PUTTY_CONF_PROT_SSH);
    putty_conf_set_username(conf, "smokeuser");

    if (strcmp(putty_conf_get_host(conf), "bridge-smoke.example") != 0)
        return -2;
    if (putty_conf_get_port(conf) != 2222)
        return -3;
    if (putty_conf_get_protocol(conf) != PUTTY_CONF_PROT_SSH)
        return -4;
    if (strcmp(putty_conf_get_username(conf), "smokeuser") != 0)
        return -5;

    if (!putty_conf_save_session(conf, putty_conf_smoke_session))
        return -6;

    loaded = putty_conf_new();
    if (!loaded) {
        putty_conf_free(conf);
        del_settings(putty_conf_smoke_session);
        return -7;
    }

    if (!putty_conf_load_session(loaded, putty_conf_smoke_session)) {
        putty_conf_free(conf);
        putty_conf_free(loaded);
        del_settings(putty_conf_smoke_session);
        return -8;
    }

    host = putty_conf_get_host(loaded);
    if (strcmp(host, "bridge-smoke.example") != 0) {
        putty_conf_free(conf);
        putty_conf_free(loaded);
        del_settings(putty_conf_smoke_session);
        return -9;
    }

    putty_conf_free(conf);
    putty_conf_free(loaded);
    del_settings(putty_conf_smoke_session);
    return 0;
}
