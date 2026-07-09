/*
 * putty-eventloop.c — event loop integration for the macOS AppKit GUI (Phase 3.4).
 */

#include <limits.h>

#include "putty-bridge-internal.h"

#include "putty-bridge-thread.h"

struct PuttyPollWrapper {
    pollwrapper *pw;
    int *fdlist;
    size_t fdcount;
    size_t fdsize;
};

static bool bridge_eventloop_ready;

static void bridge_notify_toplevel_callback(void *ctx)
{
    /*
     * Swift should poll putty_toplevel_callback_pending() on the main
     * queue (or register a wake hook here in a later phase).
     */
    (void)ctx;
}

void putty_bridge_eventloop_init(void)
{
    PUTTY_BRIDGE_ASSERT_MAIN_THREAD();
    if (bridge_eventloop_ready)
        return;
    uxsel_init();
    request_callback_notifications(bridge_notify_toplevel_callback, NULL);
    bridge_eventloop_ready = true;
}

uint64_t putty_bridge_now_ms(void)
{
    PUTTY_BRIDGE_ASSERT_MAIN_THREAD();
    return (uint64_t)GETTICKCOUNT();
}

void putty_run_timers(uint64_t now_ms)
{
    unsigned long next;

    PUTTY_BRIDGE_ASSERT_MAIN_THREAD();
    putty_bridge_eventloop_init();
    run_timers((unsigned long)now_ms, &next);
}

bool putty_toplevel_callback_pending(void)
{
    PUTTY_BRIDGE_ASSERT_MAIN_THREAD();
    putty_bridge_eventloop_init();
    return toplevel_callback_pending();
}

void putty_run_toplevel_callbacks(void)
{
    PUTTY_BRIDGE_ASSERT_MAIN_THREAD();
    putty_bridge_eventloop_init();
    run_toplevel_callbacks();
}

size_t putty_session_output(PuttySession *session, const void *data, size_t len)
{
    int sendlen;

    PUTTY_BRIDGE_ASSERT_MAIN_THREAD();
    if (!session || !session->ldisc || !data || len == 0)
        return 0;

    sendlen = (len > INT_MAX) ? INT_MAX : (int)len;
    ldisc_send(session->ldisc, data, sendlen, true);
    return (size_t)sendlen;
}

PuttyPollWrapper *putty_pollwrapper_new(void)
{
    PuttyPollWrapper *wrapper;

    PUTTY_BRIDGE_ASSERT_MAIN_THREAD();
    wrapper = snew(PuttyPollWrapper);

    putty_bridge_eventloop_init();
    wrapper->pw = pollwrap_new();
    wrapper->fdlist = NULL;
    wrapper->fdcount = 0;
    wrapper->fdsize = 0;
    return wrapper;
}

void putty_pollwrapper_free(PuttyPollWrapper *wrapper)
{
    PUTTY_BRIDGE_ASSERT_MAIN_THREAD();
    if (!wrapper)
        return;
    if (wrapper->pw)
        pollwrap_free(wrapper->pw);
    sfree(wrapper->fdlist);
    sfree(wrapper);
}

void putty_pollwrapper_clear(PuttyPollWrapper *wrapper)
{
    PUTTY_BRIDGE_ASSERT_MAIN_THREAD();
    if (!wrapper || !wrapper->pw)
        return;
    pollwrap_clear(wrapper->pw);
    wrapper->fdcount = 0;
}

void putty_uxsel_fill_pollfds(PuttyPollWrapper *wrapper)
{
    int fd, fdstate, rwx;

    PUTTY_BRIDGE_ASSERT_MAIN_THREAD();
    if (!wrapper || !wrapper->pw)
        return;

    putty_pollwrapper_clear(wrapper);

    for (fd = first_fd(&fdstate, &rwx); fd >= 0; fd = next_fd(&fdstate, &rwx)) {
        sgrowarray(wrapper->fdlist, wrapper->fdsize, wrapper->fdcount + 1);
        wrapper->fdlist[wrapper->fdcount++] = fd;
        pollwrap_add_fd_rwx(wrapper->pw, fd, rwx);
    }
}

size_t putty_uxsel_list_fds(PuttyBridgePollFd *out, size_t max_out)
{
    int fd, fdstate, rwx;
    size_t count = 0;

    PUTTY_BRIDGE_ASSERT_MAIN_THREAD();
    putty_bridge_eventloop_init();

    for (fd = first_fd(&fdstate, &rwx); fd >= 0; fd = next_fd(&fdstate, &rwx)) {
        if (out && count < max_out) {
            out[count].fd = fd;
            out[count].rwx = (unsigned int)rwx;
        }
        count++;
    }

    return count;
}

void putty_uxsel_select_result(int fd, unsigned int rwx_event)
{
    PUTTY_BRIDGE_ASSERT_MAIN_THREAD();
    putty_bridge_eventloop_init();
    if (rwx_event & PUTTY_BRIDGE_POLL_X)
        select_result(fd, SELECT_X);
    if (rwx_event & PUTTY_BRIDGE_POLL_R)
        select_result(fd, SELECT_R);
    if (rwx_event & PUTTY_BRIDGE_POLL_W)
        select_result(fd, SELECT_W);
}

int putty_pollwrapper_poll_instant(PuttyPollWrapper *wrapper)
{
    PUTTY_BRIDGE_ASSERT_MAIN_THREAD();
    if (!wrapper || !wrapper->pw)
        return -1;
    return pollwrap_poll_instant(wrapper->pw);
}

int putty_pollwrapper_poll_timeout(PuttyPollWrapper *wrapper, int timeout_ms)
{
    PUTTY_BRIDGE_ASSERT_MAIN_THREAD();
    if (!wrapper || !wrapper->pw)
        return -1;
    if (timeout_ms < 0)
        return pollwrap_poll_endless(wrapper->pw);
    return pollwrap_poll_timeout(wrapper->pw, timeout_ms);
}

void putty_pollwrapper_process_events(PuttyPollWrapper *wrapper)
{
    PUTTY_BRIDGE_ASSERT_MAIN_THREAD();
    size_t i;

    if (!wrapper || !wrapper->pw)
        return;

    for (i = 0; i < wrapper->fdcount; i++) {
        int fd = wrapper->fdlist[i];
        int rwx = pollwrap_get_fd_rwx(wrapper->pw, fd);

        if (rwx & SELECT_X)
            select_result(fd, SELECT_X);
        if (rwx & SELECT_R)
            select_result(fd, SELECT_R);
        if (rwx & SELECT_W)
            select_result(fd, SELECT_W);
    }
}

void timer_change_notify(unsigned long next)
{
    /*
     * Swift schedules the next timer via NSTimer / DispatchSource after
     * calling putty_run_timers(). Nothing to do until the AppKit loop
     * wires a wake source (Phase 5+).
     */
    (void)next;
}

int putty_bridge_eventloop_smoke(void)
{
    PUTTY_BRIDGE_ASSERT_MAIN_THREAD();
    PuttyPollWrapper *wrapper;
    PuttySession *session;
    uint64_t now;
    const char test_input[] = "x";

    putty_bridge_eventloop_init();

    now = putty_bridge_now_ms();
    putty_run_timers(now);
    if (putty_toplevel_callback_pending())
        putty_run_toplevel_callbacks();

    wrapper = putty_pollwrapper_new();
    if (!wrapper)
        return -1;

    putty_uxsel_fill_pollfds(wrapper);
    if (putty_pollwrapper_poll_instant(wrapper) < 0) {
        putty_pollwrapper_free(wrapper);
        return -2;
    }
    putty_pollwrapper_process_events(wrapper);
    putty_pollwrapper_free(wrapper);

    session = putty_session_new(NULL);
    if (!session)
        return -3;
    if (putty_session_output(session, test_input, sizeof(test_input) - 1) != 0)
        return -4;
    putty_session_free(session);

    return 0;
}
