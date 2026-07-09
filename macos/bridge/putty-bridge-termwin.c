/*
 * putty-bridge-termwin.c — Swift bridge for MacTermWin / TerminalView (Phase 4.2).
 */

#include <string.h>

#include "putty-bridge-termwin.h"

#include "putty-bridge-thread.h"
#include "termwin.h"
#include "osxkeys.h"
#include "terminal.h"

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

static void bridge_set_cursor_pos(void *ctx, int x, int y)
{
    PuttyBridgeTermWin *btw = (PuttyBridgeTermWin *)ctx;

    if (btw->swift_callbacks.set_cursor_pos)
        btw->swift_callbacks.set_cursor_pos(btw->swift_view_ctx, x, y);
}

static void bridge_set_raw_mouse_mode(void *ctx, bool enable)
{
    PuttyBridgeTermWin *btw = (PuttyBridgeTermWin *)ctx;

    if (btw->swift_callbacks.set_raw_mouse_mode)
        btw->swift_callbacks.set_raw_mouse_mode(btw->swift_view_ctx, enable);
}

static void bridge_set_raw_mouse_mode_pointer(void *ctx, bool enable)
{
    PuttyBridgeTermWin *btw = (PuttyBridgeTermWin *)ctx;

    if (btw->swift_callbacks.set_raw_mouse_mode_pointer)
        btw->swift_callbacks.set_raw_mouse_mode_pointer(
            btw->swift_view_ctx, enable);
}

static void bridge_clip_write(
    void *ctx, int clipboard, wchar_t *text, int *attrs,
    truecolour *colours, int len, bool must_deselect)
{
    PuttyBridgeTermWin *btw = (PuttyBridgeTermWin *)ctx;

    (void)attrs;
    (void)colours;
    if (!btw->swift_callbacks.clip_write)
        return;
    btw->swift_callbacks.clip_write(
        btw->swift_view_ctx, clipboard, text, len, must_deselect);
}

static void bridge_clip_request_paste(void *ctx, int clipboard)
{
    PuttyBridgeTermWin *btw = (PuttyBridgeTermWin *)ctx;

    if (btw->swift_callbacks.clip_request_paste)
        btw->swift_callbacks.clip_request_paste(btw->swift_view_ctx, clipboard);
}

static Mouse_Button bridge_translate_button(Mouse_Button button)
{
    if (button == MBT_LEFT)
        return MBT_SELECT;
    if (button == MBT_MIDDLE)
        return MBT_PASTE;
    if (button == MBT_RIGHT)
        return MBT_EXTEND;
    if (button == MBT_NOTHING)
        return MBT_NOTHING;
    return button;
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
        .set_cursor_pos = bridge_set_cursor_pos,
        .set_raw_mouse_mode = bridge_set_raw_mouse_mode,
        .set_raw_mouse_mode_pointer = bridge_set_raw_mouse_mode_pointer,
        .clip_write = bridge_clip_write,
        .clip_request_paste = bridge_clip_request_paste,
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

void putty_bridge_termwin_key_bytes(
    PuttyBridgeTermWin *btw, int32_t codepage, const void *data, int32_t len)
{
    PUTTY_BRIDGE_ASSERT_MAIN_THREAD();
    if (!btw->term || !data || len <= 0)
        return;

    term_keyinput(btw->term, codepage, data, len);
}

void putty_bridge_termwin_key_special(
    PuttyBridgeTermWin *btw, const char *nul_terminated)
{
    PUTTY_BRIDGE_ASSERT_MAIN_THREAD();
    if (!btw->term || !nul_terminated)
        return;

    term_keyinput(btw->term, -1, nul_terminated, -2);
}

void putty_bridge_termwin_key_wide(
    PuttyBridgeTermWin *btw, const wchar_t *data, int32_t len)
{
    PUTTY_BRIDGE_ASSERT_MAIN_THREAD();
    if (!btw->term || !data || len <= 0)
        return;

    term_keyinputw(btw->term, data, len);
}

int32_t putty_bridge_termwin_format_return(
    PuttyBridgeTermWin *btw, char *buf, int32_t buflen, bool *special_out)
{
    PUTTY_BRIDGE_ASSERT_MAIN_THREAD();
    if (!btw->term || !buf || buflen <= 0 || !special_out)
        return 0;

    return (int32_t)osxkeys_format_return(
        btw->term, buf, (size_t)buflen, special_out);
}

int32_t putty_bridge_termwin_format_arrow(
    PuttyBridgeTermWin *btw, int32_t xkey, bool shift, bool ctrl, bool alt,
    char *buf, int32_t buflen, bool *consumed_alt_out)
{
    PUTTY_BRIDGE_ASSERT_MAIN_THREAD();
    if (!btw->term || !buf || buflen <= 0)
        return 0;

    return (int32_t)osxkeys_format_arrow(
        btw->term, xkey, shift, ctrl, alt, buf, (size_t)buflen,
        consumed_alt_out);
}

int32_t putty_bridge_termwin_format_function(
    PuttyBridgeTermWin *btw, int32_t fkey_number, bool shift, bool ctrl,
    bool alt, char *buf, int32_t buflen, bool *consumed_alt_out)
{
    PUTTY_BRIDGE_ASSERT_MAIN_THREAD();
    if (!btw->term || !buf || buflen <= 0 || fkey_number < 1)
        return 0;

    return (int32_t)osxkeys_format_function(
        btw->term, fkey_number, shift, ctrl, alt, buf, (size_t)buflen,
        consumed_alt_out);
}

int32_t putty_bridge_termwin_format_small_keypad(
    PuttyBridgeTermWin *btw, int32_t key, bool shift, bool ctrl, bool alt,
    char *buf, int32_t buflen, bool *consumed_alt_out)
{
    PUTTY_BRIDGE_ASSERT_MAIN_THREAD();
    if (!btw->term || !buf || buflen <= 0)
        return 0;

    return (int32_t)osxkeys_format_small_keypad(
        btw->term, (SmallKeypadKey)key, shift, ctrl, alt, buf, (size_t)buflen,
        consumed_alt_out);
}

uint8_t putty_bridge_termwin_apply_ctrl(uint8_t c)
{
    return osxkeys_apply_ctrl(c);
}

void putty_bridge_termwin_mouse(
    PuttyBridgeTermWin *btw, int32_t button_raw, int32_t action,
    int32_t cell_x, int32_t cell_y, bool shift, bool ctrl, bool alt)
{
    Mouse_Button braw, bcooked;
    Mouse_Action ma;

    PUTTY_BRIDGE_ASSERT_MAIN_THREAD();
    if (!btw->term)
        return;

    braw = (Mouse_Button)button_raw;
    bcooked = bridge_translate_button(braw);
    ma = (Mouse_Action)action;

    term_mouse(btw->term, braw, bcooked, ma, cell_x, cell_y, shift, ctrl, alt);
}

void putty_bridge_termwin_scroll_lines(PuttyBridgeTermWin *btw, int32_t lines)
{
    PUTTY_BRIDGE_ASSERT_MAIN_THREAD();
    if (!btw->term || lines == 0)
        return;

    term_scroll(btw->term, 0, lines);
}

bool putty_bridge_termwin_raw_mouse_active(const PuttyBridgeTermWin *btw)
{
    Terminal *term;

    if (!btw->term)
        return false;

    term = btw->term;
    return term->xterm_mouse != 0 && !term->xterm_mouse_forbidden;
}

bool putty_bridge_termwin_pointer_indicates_raw_mouse(
    const PuttyBridgeTermWin *btw)
{
    PUTTY_BRIDGE_ASSERT_MAIN_THREAD();
    return btw->mtw->pointer_indicates_raw_mouse;
}

bool putty_bridge_termwin_mouse_override_shift(const PuttyBridgeTermWin *btw)
{
    if (!btw->conf)
        return true;
    return conf_get_bool(btw->conf, CONF_mouse_override);
}

void putty_bridge_termwin_copy_selection(PuttyBridgeTermWin *btw)
{
    static const int clips[] = { CLIP_CLIPBOARD };

    PUTTY_BRIDGE_ASSERT_MAIN_THREAD();
    if (!btw->term)
        return;

    term_request_copy(btw->term, clips, lenof(clips));
}

void putty_bridge_termwin_copy_all(PuttyBridgeTermWin *btw)
{
    static const int clips[] = { COPYALL_CLIPBOARDS };

    PUTTY_BRIDGE_ASSERT_MAIN_THREAD();
    if (!btw->term)
        return;

    term_copyall(btw->term, clips, lenof(clips));
}

void putty_bridge_termwin_select_all(PuttyBridgeTermWin *btw)
{
    Terminal *term;

    PUTTY_BRIDGE_ASSERT_MAIN_THREAD();
    if (!btw->term)
        return;

    term = btw->term;
    term->seltype = LEXICOGRAPHIC;
    term->selstate = SELECTED;
    term->selstart.x = 0;
    term->selstart.y = term->disptop;
    term->selend.x = term->cols > 0 ? term->cols - 1 : 0;
    term->selend.y = term->disptop + term->rows - 1;
    incpos_fn(&term->selend, term->cols);
    term_invalidate(term);
}

void putty_bridge_termwin_request_paste(
    PuttyBridgeTermWin *btw, int32_t clipboard)
{
    PUTTY_BRIDGE_ASSERT_MAIN_THREAD();
    if (!btw->term)
        return;

    term_request_paste(btw->term, clipboard);
}

void putty_bridge_termwin_paste_text(
    PuttyBridgeTermWin *btw, const wchar_t *data, int32_t len)
{
    PUTTY_BRIDGE_ASSERT_MAIN_THREAD();
    if (!btw->term || !data || len <= 0)
        return;

    term_do_paste(btw->term, data, len);
}

int putty_bridge_termwin_input_smoke(void)
{
    PuttyBridgeTermWin *btw;
    char buf[32];
    bool special = false;
    int len;

    btw = putty_bridge_termwin_new();
    if (!putty_bridge_termwin_init_demo(btw)) {
        putty_bridge_termwin_free(btw);
        return 1;
    }

    putty_bridge_termwin_key_bytes(btw, -1, "a", 1);
    len = putty_bridge_termwin_format_return(btw, buf, sizeof(buf), &special);
    if (len <= 0) {
        putty_bridge_termwin_free(btw);
        return 2;
    }
    if (special)
        putty_bridge_termwin_key_special(btw, buf);
    else
        putty_bridge_termwin_key_bytes(btw, -1, buf, len);

    putty_bridge_termwin_mouse(
        btw, MBT_LEFT, MA_CLICK, 1, 1, false, false, false);
    putty_bridge_termwin_mouse(
        btw, MBT_LEFT, MA_DRAG, 5, 1, false, false, false);
    putty_bridge_termwin_mouse(
        btw, MBT_LEFT, MA_RELEASE, 5, 1, false, false, false);

    putty_bridge_termwin_select_all(btw);
    putty_bridge_termwin_free(btw);
    return 0;
}
