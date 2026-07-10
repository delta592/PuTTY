/*
 * macos/platform/eventloop-appkit.m — DispatchSource uxsel + timer integration (Phase 5.4).
 *
 * Mirrors unix/gtk-common.c: registers uxsel fds on the main queue, arms PuTTY
 * timers via dispatch_source timers, and schedules toplevel callbacks without
 * blocking AppKit.
 */

#import <dispatch/dispatch.h>
#import <CoreFoundation/CoreFoundation.h>

#include <poll.h>
#include <stdbool.h>
#include <string.h>

#include "eventloop-appkit.h"

#include "putty.h"

/*
 * Store Dispatch sources as void * rather than __strong dispatch_source_t
 * inside a malloc'd C struct. ARC would otherwise release uninitialized
 * garbage when assigning NULL after snew(), which silently breaks I/O
 * (TCP ESTABLISHED, blank terminal, no host-key / password prompts).
 */
struct uxsel_id {
    int fd;
    int rwx;
    void *read_source;   /* dispatch_source_t */
    void *write_source;  /* dispatch_source_t */
};

static dispatch_source_t mac_timer_source;
static bool mac_toplevel_idle_scheduled;

static bool mac_fd_still_readable(int fd)
{
    struct pollfd pfd = { .fd = fd, .events = POLLIN, .revents = 0 };

    if (poll(&pfd, 1, 0) <= 0)
        return false;
    /*
     * Only continue draining on real readability / hangup. POLLNVAL
     * (and often POLLERR) means the fd was closed — e.g. agent_query
     * finished and uxsel_del'd the socket. Treating that as "still
     * readable" busy-loops the main thread after "Pageant has N keys"
     * and never sends USERAUTH (blank terminal, TCP ESTABLISHED).
     */
    return (pfd.revents & (POLLIN | POLLHUP)) != 0;
}

/*
 * True when uxsel still wants SELECT_R on this fd. Terminal backlog
 * freezes the NetSocket and uxsel_tell() drops SELECT_R while data can
 * still sit in the kernel buffer — poll then stays POLLIN forever, and
 * a naive drain loop beachballs the main thread.
 */
static bool mac_uxsel_wants_read(int fd)
{
    int state, rwx, f;

    for (f = first_fd(&state, &rwx); f >= 0; f = next_fd(&state, &rwx)) {
        if (f == fd)
            return (rwx & SELECT_R) != 0;
    }
    return false;
}

static void mac_uxsel_fire(int fd, int event)
{
    /*
     * Do not synthesize SELECT_X from DISPATCH_SOURCE_TYPE_READ.
     * GTK only delivers SELECT_X on G_IO_PRI. Faking it on every read
     * sets NetSocket.oobpending and forces 1-byte recv / EWOULDBLOCK
     * spins that starve the SSH state machine (blank terminal).
     *
     * DISPATCH_SOURCE_TYPE_READ is edge-triggered (kqueue). GTK's
     * G_IO_IN is level-triggered. After one recv(), more SSH data may
     * still sit in the socket buffer (e.g. a split KEXINIT) with no
     * further edge — drain until poll says the fd is quiet *and* uxsel
     * still wants SELECT_R (frozen sockets are intentionally ignored).
     *
     * run_toplevel_callbacks() runs only one queued callback per call.
     * SSH packet output is scheduled as a chain of idempotent callbacks
     * (ic_out_pq → ic_out_raw); drain the whole queue or KEXINIT sits
     * forever and the session stays blank.
     */
    if (event == SELECT_R) {
        int spins = 0;
        const int max_spins = 4096;

        do {
            if (!mac_uxsel_wants_read(fd))
                break;
            select_result(fd, SELECT_R);
            while (run_toplevel_callbacks())
                ;
            if (++spins >= max_spins)
                break;
        } while (mac_fd_still_readable(fd));
        return;
    }

    select_result(fd, event);
    while (run_toplevel_callbacks())
        ;
}

uxsel_id *uxsel_input_add(int fd, int rwx)
{
    uxsel_id *id = snew(uxsel_id);
    dispatch_queue_t queue = dispatch_get_main_queue();

    memset(id, 0, sizeof(*id));

    /*
     * DISPATCH_SOURCE_TYPE_{READ,WRITE} require non-blocking fds.
     * Network sockets already call nonblock(); agent queries and other
     * helpers historically did not.
     */
    nonblock(fd);

    id->fd = fd;
    id->rwx = rwx;

    if (rwx & (SELECT_R | SELECT_X)) {
        dispatch_source_t src = dispatch_source_create(
            DISPATCH_SOURCE_TYPE_READ, (uintptr_t)fd, 0, queue);
        dispatch_source_set_event_handler(src, ^{
            mac_uxsel_fire(fd, SELECT_R);
        });
        /*
         * Retain explicitly: we store as void * and free via cancel.
         * dispatch_resume does not transfer ownership.
         */
        id->read_source = (__bridge_retained void *)src;
        dispatch_resume(src);
    }

    if (rwx & SELECT_W) {
        dispatch_source_t src = dispatch_source_create(
            DISPATCH_SOURCE_TYPE_WRITE, (uintptr_t)fd, 0, queue);
        dispatch_source_set_event_handler(src, ^{
            mac_uxsel_fire(fd, SELECT_W);
        });
        id->write_source = (__bridge_retained void *)src;
        dispatch_resume(src);
    }

    return id;
}

void uxsel_input_remove(uxsel_id *id)
{
    if (!id)
        return;
    if (id->read_source) {
        dispatch_source_t src =
            (__bridge_transfer dispatch_source_t)id->read_source;
        id->read_source = NULL;
        dispatch_source_cancel(src);
    }
    if (id->write_source) {
        dispatch_source_t src =
            (__bridge_transfer dispatch_source_t)id->write_source;
        id->write_source = NULL;
        dispatch_source_cancel(src);
    }
    sfree(id);
}

static void mac_timer_arm(unsigned long next)
{
    long ticks = (long)(next - GETTICKCOUNT());

    if (mac_timer_source) {
        dispatch_source_cancel(mac_timer_source);
        mac_timer_source = NULL;
    }

    if (ticks < 1)
        ticks = 1;

    mac_timer_source = dispatch_source_create(
        DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
    dispatch_source_set_timer(
        mac_timer_source,
        dispatch_time(DISPATCH_TIME_NOW, (int64_t)ticks * NSEC_PER_MSEC),
        DISPATCH_TIME_FOREVER, 0);
    dispatch_source_set_event_handler(mac_timer_source, ^{
        unsigned long now = GETTICKCOUNT();
        unsigned long next_deadline;

        if (mac_timer_source) {
            dispatch_source_cancel(mac_timer_source);
            mac_timer_source = NULL;
        }

        if (run_timers(now, &next_deadline) && !mac_timer_source)
            mac_timer_arm(next_deadline);

        while (run_toplevel_callbacks())
            ;
    });
    dispatch_resume(mac_timer_source);
}

void timer_change_notify(unsigned long next)
{
    mac_timer_arm(next);
}

void mac_eventloop_schedule_toplevel_callbacks(void *ctx)
{
    (void)ctx;

    if (mac_toplevel_idle_scheduled)
        return;
    mac_toplevel_idle_scheduled = true;

    dispatch_async(dispatch_get_main_queue(), ^{
        mac_toplevel_idle_scheduled = false;
        while (run_toplevel_callbacks())
            ;
    });
}

void mac_eventloop_pump_once(void)
{
    CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.05, true);
}
