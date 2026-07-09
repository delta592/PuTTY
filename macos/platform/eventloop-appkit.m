/*
 * macos/platform/eventloop-appkit.m — DispatchSource uxsel + timer integration (Phase 5.4).
 *
 * Mirrors unix/gtk-common.c: registers uxsel fds on the main queue, arms PuTTY
 * timers via dispatch_source timers, and schedules toplevel callbacks without
 * blocking AppKit.
 */

#import <dispatch/dispatch.h>
#import <CoreFoundation/CoreFoundation.h>

#include <stdbool.h>

#include "eventloop-appkit.h"

#include "putty.h"

struct uxsel_id {
    int fd;
    int rwx;
    dispatch_source_t read_source;
    dispatch_source_t write_source;
};

static dispatch_source_t mac_timer_source;
static bool mac_toplevel_idle_scheduled;

static void mac_uxsel_fire(int fd, int rwx, int event)
{
    if (event == SELECT_R && (rwx & SELECT_X))
        select_result(fd, SELECT_X);
    select_result(fd, event);
    run_toplevel_callbacks();
}

static void mac_uxsel_cancel_source(dispatch_source_t *src)
{
    if (!src || !*src)
        return;
    dispatch_source_cancel(*src);
    *src = NULL;
}

uxsel_id *uxsel_input_add(int fd, int rwx)
{
    uxsel_id *id = snew(uxsel_id);
    dispatch_queue_t queue = dispatch_get_main_queue();

    id->fd = fd;
    id->rwx = rwx;
    id->read_source = NULL;
    id->write_source = NULL;

    if (rwx & (SELECT_R | SELECT_X)) {
        id->read_source = dispatch_source_create(
            DISPATCH_SOURCE_TYPE_READ, (uintptr_t)fd, 0, queue);
        dispatch_source_set_event_handler(id->read_source, ^{
            mac_uxsel_fire(fd, rwx, SELECT_R);
        });
        dispatch_resume(id->read_source);
    }

    if (rwx & SELECT_W) {
        id->write_source = dispatch_source_create(
            DISPATCH_SOURCE_TYPE_WRITE, (uintptr_t)fd, 0, queue);
        dispatch_source_set_event_handler(id->write_source, ^{
            mac_uxsel_fire(fd, rwx, SELECT_W);
        });
        dispatch_resume(id->write_source);
    }

    return id;
}

void uxsel_input_remove(uxsel_id *id)
{
    if (!id)
        return;
    mac_uxsel_cancel_source(&id->read_source);
    mac_uxsel_cancel_source(&id->write_source);
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

        run_toplevel_callbacks();
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
        run_toplevel_callbacks();
    });
}

void mac_eventloop_pump_once(void)
{
    CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.05, true);
}
