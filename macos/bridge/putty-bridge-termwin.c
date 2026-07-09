/*
 * putty-bridge-termwin.c — Swift bridge for MacTermWin / TerminalView (Phase 4.2).
 */

#include <string.h>

#include "putty-bridge-termwin.h"

#include "putty-bridge-thread.h"
#include "termwin.h"

struct PuttyBridgeTermWin {
    MacTermWin *mtw;
    Conf *conf;
    Terminal *term;
    struct unicode_data ucsdata;
    bool demo_initialised;
    PuttyBridgeTermWinCallbacks swift_callbacks;
    void *swift_view_ctx;
};

static PuttyBridgeOptionalRgb bridge_optional_rgb(optionalrgb rgb)
{
    PuttyBridgeOptionalRgb out;

    out.enabled = rgb.enabled;
    out.r = rgb.r;
    out.g = rgb.g;
    out.b = rgb.b;
    return out;
}

static PuttyBridgeTermWinDrawParams bridge_draw_params(
    const MacTermWinDrawParams *params)
{
    PuttyBridgeTermWinDrawParams out;

    out.x = params->x;
    out.y = params->y;
    out.text = params->text;
    out.len = params->len;
    out.attr = (uint32_t)params->attr;
    out.lattr = params->lattr;
    out.truecolour.fg = bridge_optional_rgb(params->tc.fg);
    out.truecolour.bg = bridge_optional_rgb(params->tc.bg);
    return out;
}

static bool bridge_setup_draw_ctx(void *ctx)
{
    PuttyBridgeTermWin *btw = (PuttyBridgeTermWin *)ctx;

    if (btw->swift_callbacks.setup_draw_ctx)
        return btw->swift_callbacks.setup_draw_ctx(btw->swift_view_ctx);
    return true;
}

static void bridge_free_draw_ctx(void *ctx)
{
    PuttyBridgeTermWin *btw = (PuttyBridgeTermWin *)ctx;

    if (btw->swift_callbacks.free_draw_ctx)
        btw->swift_callbacks.free_draw_ctx(btw->swift_view_ctx);
}

static void bridge_draw_text(void *ctx, const MacTermWinDrawParams *params)
{
    PuttyBridgeTermWin *btw = (PuttyBridgeTermWin *)ctx;
    PuttyBridgeTermWinDrawParams swift_params;

    if (!btw->swift_callbacks.draw_text)
        return;

    swift_params = bridge_draw_params(params);
    btw->swift_callbacks.draw_text(btw->swift_view_ctx, &swift_params);
}

static void bridge_draw_cursor(void *ctx, const MacTermWinDrawParams *params)
{
    PuttyBridgeTermWin *btw = (PuttyBridgeTermWin *)ctx;
    PuttyBridgeTermWinDrawParams swift_params;

    if (!btw->swift_callbacks.draw_cursor)
        return;

    swift_params = bridge_draw_params(params);
    btw->swift_callbacks.draw_cursor(btw->swift_view_ctx, &swift_params);
}

static void bridge_draw_trust_sigil(void *ctx, int x, int y)
{
    PuttyBridgeTermWin *btw = (PuttyBridgeTermWin *)ctx;

    if (btw->swift_callbacks.draw_trust_sigil)
        btw->swift_callbacks.draw_trust_sigil(btw->swift_view_ctx, x, y);
}

static void bridge_request_redraw(void *ctx, MacTermWinRect dirty)
{
    PuttyBridgeTermWin *btw = (PuttyBridgeTermWin *)ctx;
    PuttyBridgeTermWinRect swift_dirty;

    if (!btw->swift_callbacks.request_redraw)
        return;

    swift_dirty.x = dirty.x;
    swift_dirty.y = dirty.y;
    swift_dirty.width = dirty.width;
    swift_dirty.height = dirty.height;
    btw->swift_callbacks.request_redraw(btw->swift_view_ctx, swift_dirty);
}

static int bridge_char_width(void *ctx, int uc)
{
    PuttyBridgeTermWin *btw = (PuttyBridgeTermWin *)ctx;

    if (btw->swift_callbacks.char_width)
        return btw->swift_callbacks.char_width(btw->swift_view_ctx, uc);
    return 1;
}

static void bridge_install_termwin_callbacks(PuttyBridgeTermWin *btw)
{
    static const MacTermWinCallbacks internal_cbs = {
        .setup_draw_ctx = bridge_setup_draw_ctx,
        .free_draw_ctx = bridge_free_draw_ctx,
        .draw_text = bridge_draw_text,
        .draw_cursor = bridge_draw_cursor,
        .draw_trust_sigil = bridge_draw_trust_sigil,
        .char_width = bridge_char_width,
        .request_redraw = bridge_request_redraw,
    };

    mac_termwin_set_callbacks(btw->mtw, &internal_cbs, btw);
}

PuttyBridgeTermWin *putty_bridge_termwin_new(void)
{
    PuttyBridgeTermWin *btw = snew(PuttyBridgeTermWin);

    memset(btw, 0, sizeof(*btw));
    btw->mtw = mac_termwin_new();
    bridge_install_termwin_callbacks(btw);
    return btw;
}

void putty_bridge_termwin_free(PuttyBridgeTermWin *btw)
{
    if (!btw)
        return;

    if (btw->term) {
        term_free(btw->term);
        btw->term = NULL;
    }
    if (btw->conf) {
        conf_free(btw->conf);
        btw->conf = NULL;
    }
    mac_termwin_free(btw->mtw);
    sfree(btw);
}

void putty_bridge_termwin_set_callbacks(
    PuttyBridgeTermWin *btw,
    const PuttyBridgeTermWinCallbacks *callbacks,
    void *view_ctx)
{
    PUTTY_BRIDGE_ASSERT_MAIN_THREAD();
    if (callbacks)
        btw->swift_callbacks = *callbacks;
    else
        memset(&btw->swift_callbacks, 0, sizeof(btw->swift_callbacks));
    btw->swift_view_ctx = view_ctx;
}

bool putty_bridge_termwin_init_demo(PuttyBridgeTermWin *btw)
{
    static const char banner[] =
        "PuTTY for macOS — TerminalView (Phase 4.2)\r\n\r\n";

    PUTTY_BRIDGE_ASSERT_MAIN_THREAD();
    if (btw->demo_initialised)
        return true;

    btw->conf = conf_new();
    do_defaults(NULL, btw->conf);
    init_ucs_generic(btw->conf, &btw->ucsdata);

    mac_termwin_set_conf(btw->mtw, btw->conf);
    btw->term = term_init(btw->conf, &btw->ucsdata, mac_termwin_get_termwin(btw->mtw));
    if (!btw->term)
        return false;

    mac_termwin_set_terminal(btw->mtw, btw->term);
    btw->term->ldisc = NULL;
    term_size(btw->term, 24, 80, conf_get_int(btw->conf, CONF_savelines));

    term_data(btw->term, banner, sizeof(banner) - 1);
    term_update(btw->term);

    btw->demo_initialised = true;
    return true;
}

void putty_bridge_termwin_set_backing_scale(PuttyBridgeTermWin *btw, double scale)
{
    PUTTY_BRIDGE_ASSERT_MAIN_THREAD();
    mac_termwin_set_backing_scale(btw->mtw, scale);
}

double putty_bridge_termwin_get_backing_scale(const PuttyBridgeTermWin *btw)
{
    PUTTY_BRIDGE_ASSERT_MAIN_THREAD();
    return mac_termwin_get_backing_scale(btw->mtw);
}

void putty_bridge_termwin_set_font_metrics(
    PuttyBridgeTermWin *btw, double cell_width_pt, double cell_height_pt,
    double ascent_pt, double descent_pt)
{
    PUTTY_BRIDGE_ASSERT_MAIN_THREAD();
    mac_termwin_set_font_metrics(
        btw->mtw, cell_width_pt, cell_height_pt, ascent_pt, descent_pt);
}

double putty_bridge_termwin_cell_width_pt(const PuttyBridgeTermWin *btw)
{
    return btw->mtw->cell_width_pt;
}

double putty_bridge_termwin_cell_height_pt(const PuttyBridgeTermWin *btw)
{
    return btw->mtw->cell_height_pt;
}

void putty_bridge_termwin_resize_to_view(
    PuttyBridgeTermWin *btw, double view_width_pt, double view_height_pt)
{
    int cols, rows;

    PUTTY_BRIDGE_ASSERT_MAIN_THREAD();
    if (!btw->term)
        return;

    cols = (int)(view_width_pt / btw->mtw->cell_width_pt);
    rows = (int)(view_height_pt / btw->mtw->cell_height_pt);
    if (cols < 1)
        cols = 1;
    if (rows < 1)
        rows = 1;

    if (btw->term->cols != cols || btw->term->rows != rows)
        term_size(btw->term, rows, cols, conf_get_int(btw->conf, CONF_savelines));
}

void putty_bridge_termwin_paint(
    PuttyBridgeTermWin *btw, int32_t left, int32_t top,
    int32_t right, int32_t bottom)
{
    PUTTY_BRIDGE_ASSERT_MAIN_THREAD();
    if (!btw->term)
        return;

    term_paint(btw->term, left, top, right, bottom, true);
}

bool putty_bridge_termwin_palette_colour(
    const PuttyBridgeTermWin *btw, uint32_t index,
    uint8_t *r, uint8_t *g, uint8_t *b)
{
    const rgb *colours;

    PUTTY_BRIDGE_ASSERT_MAIN_THREAD();
    if (index >= OSC4_NCOLOURS)
        return false;

    colours = mac_termwin_get_colours(btw->mtw);
    *r = colours[index].r;
    *g = colours[index].g;
    *b = colours[index].b;
    return true;
}

int32_t putty_bridge_termwin_cols(const PuttyBridgeTermWin *btw)
{
    if (!btw->term)
        return 0;
    return btw->term->cols;
}

int32_t putty_bridge_termwin_rows(const PuttyBridgeTermWin *btw)
{
    if (!btw->term)
        return 0;
    return btw->term->rows;
}

double putty_bridge_termwin_ascent_pt(const PuttyBridgeTermWin *btw)
{
    PUTTY_BRIDGE_ASSERT_MAIN_THREAD();
    return btw->mtw->ascent_pt;
}

int32_t putty_bridge_termwin_cursor_type(const PuttyBridgeTermWin *btw)
{
    PUTTY_BRIDGE_ASSERT_MAIN_THREAD();
    return btw->mtw->cursor_type;
}

int32_t putty_bridge_termwin_bold_style(const PuttyBridgeTermWin *btw)
{
    PUTTY_BRIDGE_ASSERT_MAIN_THREAD();
    return btw->mtw->bold_style;
}

bool putty_bridge_termwin_resize_grid(
    PuttyBridgeTermWin *btw, int32_t cols, int32_t rows)
{
    PUTTY_BRIDGE_ASSERT_MAIN_THREAD();
    if (!btw->term || cols < 1 || rows < 1)
        return false;

    term_size(btw->term, rows, cols, conf_get_int(btw->conf, CONF_savelines));
    return true;
}

size_t putty_bridge_termwin_feed(
    PuttyBridgeTermWin *btw, const void *data, size_t len)
{
    PUTTY_BRIDGE_ASSERT_MAIN_THREAD();
    if (!btw->term || !data || len == 0)
        return 0;

    term_data(btw->term, data, len);
    term_update(btw->term);
    return len;
}

bool putty_bridge_termwin_compute_dirty_rect(
    PuttyBridgeTermWin *btw, PuttyBridgeTermWinRect *out)
{
    MacTermWinRect dirty;

    PUTTY_BRIDGE_ASSERT_MAIN_THREAD();
    if (!out || !mac_termwin_compute_dirty_rect(btw->mtw, &dirty))
        return false;

    out->x = dirty.x;
    out->y = dirty.y;
    out->width = dirty.width;
    out->height = dirty.height;
    return true;
}

int putty_bridge_termwin_perf_paint_benchmark(
    PuttyBridgeTermWin *btw, int frames, double budget_ms)
{
    Terminal *term;
    uint64_t start, end, total;
    double mean_ms;
    int cols, rows;
    const char line[] =
        "abcdefghijklmnopqrstuvwxyz0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ\r\n";
    int i;

    if (getenv("PUTTY_BRIDGE_PERF_SKIP"))
        return 0;

    PUTTY_BRIDGE_ASSERT_MAIN_THREAD();
    if (!btw->term || frames < 1 || budget_ms <= 0.0)
        return 1;

    term = btw->term;
    cols = term->cols;
    rows = term->rows;

    for (i = 0; i < rows; i++)
        term_data(term, line, sizeof(line) - 1);
    term_update(term);

    start = GETTICKCOUNT();
    for (i = 0; i < frames; i++)
        term_paint(term, 0, 0, cols - 1, rows - 1, true);
    end = GETTICKCOUNT();

    total = end - start;
    mean_ms = (double)total / (double)frames;
    if (mean_ms >= budget_ms)
        return (int)(mean_ms + 0.5);

    return 0;
}
