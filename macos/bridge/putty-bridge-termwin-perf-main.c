/*
 * Phase 4.4 terminal paint performance benchmark (C driver).
 */

#include <stdio.h>
#include <stdlib.h>

#include "putty-bridge-termwin.h"

static bool noop_setup(void *ctx) { (void)ctx; return true; }
static void noop_free(void *ctx) { (void)ctx; }
static void noop_draw(void *ctx, const PuttyBridgeTermWinDrawParams *p)
{ (void)ctx; (void)p; }
static void noop_sigil(void *ctx, int32_t x, int32_t y)
{ (void)ctx; (void)x; (void)y; }
static void noop_redraw(void *ctx, PuttyBridgeTermWinRect dirty)
{ (void)ctx; (void)dirty; }
static int32_t noop_char_width(void *ctx, int32_t uc)
{ (void)ctx; (void)uc; return 1; }

int main(void)
{
    PuttyBridgeTermWin *btw;
    PuttyBridgeTermWinCallbacks cbs = {
        .setup_draw_ctx = noop_setup,
        .free_draw_ctx = noop_free,
        .draw_text = noop_draw,
        .draw_cursor = noop_draw,
        .draw_trust_sigil = noop_sigil,
        .request_redraw = noop_redraw,
        .char_width = noop_char_width,
    };
    int rc;
    const double budget_ms = 1000.0 / 60.0;
    const int frames = 120;

    btw = putty_bridge_termwin_new();
    putty_bridge_termwin_set_callbacks(btw, &cbs, NULL);

    if (!putty_bridge_termwin_init_demo(btw)) {
        fputs("putty_bridge_termwin_init_demo failed\n", stderr);
        return EXIT_FAILURE;
    }

    if (!putty_bridge_termwin_resize_grid(btw, 80, 120)) {
        fputs("putty_bridge_termwin_resize_grid failed\n", stderr);
        return EXIT_FAILURE;
    }

    rc = putty_bridge_termwin_perf_paint_benchmark(btw, frames, budget_ms);
    putty_bridge_termwin_free(btw);

    if (rc != 0) {
        fprintf(stderr,
                "perf gate failed: mean frame %.1f ms (budget %.2f ms for 60 fps)\n",
                (double)rc, budget_ms);
        return EXIT_FAILURE;
    }

    printf("putty-bridge-termwin-perf: ok (120x80, %d frames, budget %.2f ms)\n",
           frames, budget_ms);
    return EXIT_SUCCESS;
}
