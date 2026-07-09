/*
 * macos/platform/termwin.c — MacTermWin TermWinVtable (Phase 4.1).
 */

#include <assert.h>
#include <string.h>

#include "termwin.h"

#include "platform.h"

static const TermWinVtable mac_termwin_vt;

static MacTermWin *mtw_from_termwin(TermWin *tw)
{
    return container_of(tw, MacTermWin, termwin);
}

static MacTermWinRect mtw_full_view_dirty(const MacTermWin *mtw)
{
    MacTermWinRect dirty = {0, 0, 0, 0};

    if (!mtw->term)
        return dirty;

    dirty.width = mtw->term->cols * mtw->cell_width_pt;
    dirty.height = mtw->term->rows * mtw->cell_height_pt;
    return dirty;
}

static MacTermWinRect mtw_dirty_rect_from_terminal(const MacTermWin *mtw)
{
    Terminal *term = mtw->term;
    MacTermWinRect dirty = {0, 0, 0, 0};
    int minx, miny, maxx, maxy;
    int x, y;

    if (!term)
        return mtw_full_view_dirty(mtw);

    minx = term->cols;
    miny = term->rows;
    maxx = -1;
    maxy = -1;

    for (y = 0; y < term->rows; y++) {
        for (x = 0; x < term->cols; x++) {
            if (term->disptext[y]->chars[x].attr & ATTR_INVALID) {
                if (x < minx)
                    minx = x;
                if (x > maxx)
                    maxx = x;
                if (y < miny)
                    miny = y;
                if (y > maxy)
                    maxy = y;
            }
        }
    }

    if (maxx < 0)
        return mtw_full_view_dirty(mtw);

    dirty.x = minx * mtw->cell_width_pt;
    dirty.y = miny * mtw->cell_height_pt;
    dirty.width = (maxx - minx + 1) * mtw->cell_width_pt;
    dirty.height = (maxy - miny + 1) * mtw->cell_height_pt;
    return dirty;
}

static void mtw_request_redraw(MacTermWin *mtw, MacTermWinRect dirty)
{
    if (mtw->callbacks.request_redraw)
        mtw->callbacks.request_redraw(mtw->view_ctx, dirty);
}

static MacTermWinDrawParams mtw_make_draw_params(
    int x, int y, wchar_t *text, int len, unsigned long attr, int lattr,
    truecolour tc)
{
    MacTermWinDrawParams params;

    params.x = x;
    params.y = y;
    params.text = text;
    params.len = len;
    params.attr = attr;
    params.lattr = lattr;
    params.tc = tc;
    return params;
}

/* --- TermWinVtable --- */

static bool mac_tw_setup_draw_ctx(TermWin *tw)
{
    MacTermWin *mtw = mtw_from_termwin(tw);

    if (mtw->callbacks.setup_draw_ctx &&
        !mtw->callbacks.setup_draw_ctx(mtw->view_ctx))
        return false;

    mtw->draw_ctx_active = true;
    return true;
}

static void mac_tw_free_draw_ctx(TermWin *tw)
{
    MacTermWin *mtw = mtw_from_termwin(tw);

    if (mtw->callbacks.free_draw_ctx)
        mtw->callbacks.free_draw_ctx(mtw->view_ctx);
    mtw->draw_ctx_active = false;
}

static void mac_tw_draw_text(
    TermWin *tw, int x, int y, wchar_t *text, int len, unsigned long attr,
    int lattr, truecolour tc)
{
    MacTermWin *mtw = mtw_from_termwin(tw);
    MacTermWinDrawParams params;

    if (!mtw->callbacks.draw_text)
        return;

    params = mtw_make_draw_params(x, y, text, len, attr, lattr, tc);
    mtw->callbacks.draw_text(mtw->view_ctx, &params);
}

static void mac_tw_draw_cursor(
    TermWin *tw, int x, int y, wchar_t *text, int len, unsigned long attr,
    int lattr, truecolour tc)
{
    MacTermWin *mtw = mtw_from_termwin(tw);
    MacTermWinDrawParams params;

    if (!mtw->callbacks.draw_cursor)
        return;

    params = mtw_make_draw_params(x, y, text, len, attr, lattr, tc);
    mtw->callbacks.draw_cursor(mtw->view_ctx, &params);
}

static void mac_tw_draw_trust_sigil(TermWin *tw, int x, int y)
{
    MacTermWin *mtw = mtw_from_termwin(tw);

    if (mtw->callbacks.draw_trust_sigil)
        mtw->callbacks.draw_trust_sigil(mtw->view_ctx, x, y);
}

static int mac_tw_char_width(TermWin *tw, int uc)
{
    MacTermWin *mtw = mtw_from_termwin(tw);

    if (mtw->callbacks.char_width)
        return mtw->callbacks.char_width(mtw->view_ctx, uc);

    /*
     * Phase 4.3 replaces this with Core Text measurement. Until then,
     * match GTK: width variants are handled via separate fonts in draw.
     */
    (void)uc;
    return 1;
}

static void mac_tw_set_cursor_pos(TermWin *tw, int x, int y)
{
    MacTermWin *mtw = mtw_from_termwin(tw);

    mtw->caret_x = x;
    mtw->caret_y = y;
    if (mtw->callbacks.set_cursor_pos)
        mtw->callbacks.set_cursor_pos(mtw->view_ctx, x, y);
}

static void mac_tw_set_raw_mouse_mode(TermWin *tw, bool enable)
{
    MacTermWin *mtw = mtw_from_termwin(tw);

    mtw->send_raw_mouse = enable;
    if (mtw->callbacks.set_raw_mouse_mode)
        mtw->callbacks.set_raw_mouse_mode(mtw->view_ctx, enable);
}

static void mac_tw_set_raw_mouse_mode_pointer(TermWin *tw, bool enable)
{
    MacTermWin *mtw = mtw_from_termwin(tw);

    mtw->pointer_indicates_raw_mouse = enable;
    if (mtw->callbacks.set_raw_mouse_mode_pointer)
        mtw->callbacks.set_raw_mouse_mode_pointer(mtw->view_ctx, enable);
}

static void mac_tw_set_scrollbar(TermWin *tw, int total, int start, int page)
{
    MacTermWin *mtw = mtw_from_termwin(tw);

    mtw->scroll_total = total;
    mtw->scroll_start = start;
    mtw->scroll_page = page;

    if (mtw->conf && !conf_get_bool(mtw->conf, CONF_scrollbar))
        return;

    if (mtw->callbacks.set_scrollbar)
        mtw->callbacks.set_scrollbar(mtw->view_ctx, total, start, page);
}

static void mac_tw_bell(TermWin *tw, int mode)
{
    MacTermWin *mtw = mtw_from_termwin(tw);

    if (mtw->callbacks.bell)
        mtw->callbacks.bell(mtw->view_ctx, mode);
}

static void mac_tw_clip_write(
    TermWin *tw, int clipboard, wchar_t *text, int *attrs,
    truecolour *colours, int len, bool must_deselect)
{
    MacTermWin *mtw = mtw_from_termwin(tw);

    if (mtw->callbacks.clip_write)
        mtw->callbacks.clip_write(
            mtw->view_ctx, clipboard, text, attrs, colours, len,
            must_deselect);
}

static void mac_tw_clip_request_paste(TermWin *tw, int clipboard)
{
    MacTermWin *mtw = mtw_from_termwin(tw);

    if (mtw->callbacks.clip_request_paste)
        mtw->callbacks.clip_request_paste(mtw->view_ctx, clipboard);
}

static void mac_tw_refresh(TermWin *tw)
{
    MacTermWin *mtw = mtw_from_termwin(tw);

    if (mtw->term)
        mtw_request_redraw(mtw, mtw_dirty_rect_from_terminal(mtw));
}

static void mac_tw_request_resize(TermWin *tw, int w, int h)
{
    MacTermWin *mtw = mtw_from_termwin(tw);

    if (mtw->callbacks.request_resize) {
        mtw->callbacks.request_resize(mtw->view_ctx, w, h);
        return;
    }

    if (mtw->term)
        term_resize_request_completed(mtw->term);
}

static void mac_tw_set_title(TermWin *tw, const char *title, int codepage)
{
    MacTermWin *mtw = mtw_from_termwin(tw);

    if (mtw->callbacks.set_title)
        mtw->callbacks.set_title(mtw->view_ctx, title, codepage);
}

static void mac_tw_set_icon_title(TermWin *tw, const char *title, int codepage)
{
    MacTermWin *mtw = mtw_from_termwin(tw);

    if (mtw->callbacks.set_icon_title)
        mtw->callbacks.set_icon_title(mtw->view_ctx, title, codepage);
}

static void mac_tw_set_minimised(TermWin *tw, bool minimised)
{
    MacTermWin *mtw = mtw_from_termwin(tw);

    if (mtw->callbacks.set_minimised)
        mtw->callbacks.set_minimised(mtw->view_ctx, minimised);
}

static void mac_tw_set_maximised(TermWin *tw, bool maximised)
{
    MacTermWin *mtw = mtw_from_termwin(tw);

    if (mtw->callbacks.set_maximised)
        mtw->callbacks.set_maximised(mtw->view_ctx, maximised);
}

static void mac_tw_move(TermWin *tw, int x, int y)
{
    MacTermWin *mtw = mtw_from_termwin(tw);

    if (mtw->callbacks.move)
        mtw->callbacks.move(mtw->view_ctx, x, y);
}

static void mac_tw_set_zorder(TermWin *tw, bool top)
{
    MacTermWin *mtw = mtw_from_termwin(tw);

    if (mtw->callbacks.set_zorder)
        mtw->callbacks.set_zorder(mtw->view_ctx, top);
}

static void mac_tw_palette_set(
    TermWin *tw, unsigned start, unsigned ncolours, const rgb *colours_in)
{
    MacTermWin *mtw = mtw_from_termwin(tw);

    assert(start <= OSC4_NCOLOURS);
    assert(ncolours <= OSC4_NCOLOURS - start);

    for (unsigned i = 0; i < ncolours; i++)
        mtw->colours[start + i] = colours_in[i];

    if (start <= OSC4_COLOUR_bg && OSC4_COLOUR_bg < start + ncolours)
        mtw_request_redraw(mtw, mtw_full_view_dirty(mtw));
}

static void mac_tw_palette_get_overrides(TermWin *tw, Terminal *term)
{
    /*
     * macOS has no Windows-style "use system colours" palette source; AppKit
     * theme colours are applied in TerminalView (Phase 4.2) if desired.
     */
    (void)tw;
    (void)term;
}

static void mac_tw_unthrottle(TermWin *tw, size_t bufsize)
{
    MacTermWin *mtw = mtw_from_termwin(tw);

    if (mtw->backend)
        backend_unthrottle(mtw->backend, bufsize);
}

static const TermWinVtable mac_termwin_vt = {
    .setup_draw_ctx = mac_tw_setup_draw_ctx,
    .draw_text = mac_tw_draw_text,
    .draw_cursor = mac_tw_draw_cursor,
    .draw_trust_sigil = mac_tw_draw_trust_sigil,
    .char_width = mac_tw_char_width,
    .free_draw_ctx = mac_tw_free_draw_ctx,
    .set_cursor_pos = mac_tw_set_cursor_pos,
    .set_raw_mouse_mode = mac_tw_set_raw_mouse_mode,
    .set_raw_mouse_mode_pointer = mac_tw_set_raw_mouse_mode_pointer,
    .set_scrollbar = mac_tw_set_scrollbar,
    .bell = mac_tw_bell,
    .clip_write = mac_tw_clip_write,
    .clip_request_paste = mac_tw_clip_request_paste,
    .refresh = mac_tw_refresh,
    .request_resize = mac_tw_request_resize,
    .set_title = mac_tw_set_title,
    .set_icon_title = mac_tw_set_icon_title,
    .set_minimised = mac_tw_set_minimised,
    .set_maximised = mac_tw_set_maximised,
    .move = mac_tw_move,
    .set_zorder = mac_tw_set_zorder,
    .palette_set = mac_tw_palette_set,
    .palette_get_overrides = mac_tw_palette_get_overrides,
    .unthrottle = mac_tw_unthrottle,
};

/* --- Public API --- */

MacTermWin *mac_termwin_new(void)
{
    MacTermWin *mtw = snew(MacTermWin);

    memset(mtw, 0, sizeof(*mtw));
    mtw->termwin.vt = &mac_termwin_vt;
    mtw->backing_scale = 1.0;
    mtw->cell_width_pt = PUTTY_MAC_FONT_POINT_SIZE * 0.6;
    mtw->cell_height_pt = PUTTY_MAC_FONT_POINT_SIZE * 1.2;
    mtw->ascent_pt = PUTTY_MAC_FONT_POINT_SIZE;
    mtw->descent_pt = PUTTY_MAC_FONT_POINT_SIZE * 0.2;
    return mtw;
}

void mac_termwin_free(MacTermWin *mtw)
{
    if (!mtw)
        return;
    assert(!mtw->draw_ctx_active);
    sfree(mtw);
}

TermWin *mac_termwin_get_termwin(MacTermWin *mtw)
{
    return &mtw->termwin;
}

MacTermWin *mac_termwin_from_termwin(TermWin *tw)
{
    return mtw_from_termwin(tw);
}

void mac_termwin_set_callbacks(
    MacTermWin *mtw, const MacTermWinCallbacks *callbacks, void *view_ctx)
{
    if (callbacks)
        mtw->callbacks = *callbacks;
    else
        memset(&mtw->callbacks, 0, sizeof(mtw->callbacks));
    mtw->view_ctx = view_ctx;
}

void mac_termwin_set_view_ctx(MacTermWin *mtw, void *view_ctx)
{
    mtw->view_ctx = view_ctx;
}

void mac_termwin_set_terminal(MacTermWin *mtw, Terminal *term)
{
    mtw->term = term;
}

void mac_termwin_set_backend(MacTermWin *mtw, Backend *backend)
{
    mtw->backend = backend;
}

void mac_termwin_set_conf(MacTermWin *mtw, Conf *conf)
{
    mtw->conf = conf;
    mac_termwin_cache_conf_values(mtw);
}

void mac_termwin_cache_conf_values(MacTermWin *mtw)
{
    if (!mtw->conf)
        return;

    mtw->cursor_type = conf_get_int(mtw->conf, CONF_cursor_type);
    mtw->bold_style = conf_get_int(mtw->conf, CONF_bold_style);
}

void mac_termwin_set_backing_scale(MacTermWin *mtw, double scale)
{
    if (scale <= 0.0)
        scale = 1.0;
    mtw->backing_scale = scale;
}

double mac_termwin_get_backing_scale(const MacTermWin *mtw)
{
    return mtw->backing_scale;
}

void mac_termwin_set_font_metrics(
    MacTermWin *mtw, double cell_width_pt, double cell_height_pt,
    double ascent_pt, double descent_pt)
{
    mtw->cell_width_pt = cell_width_pt;
    mtw->cell_height_pt = cell_height_pt;
    mtw->ascent_pt = ascent_pt;
    mtw->descent_pt = descent_pt;
}

const rgb *mac_termwin_get_colours(const MacTermWin *mtw)
{
    return mtw->colours;
}

bool mac_termwin_compute_dirty_rect(const MacTermWin *mtw, MacTermWinRect *out)
{
    MacTermWinRect dirty;

    if (!out)
        return false;

    dirty = mtw_dirty_rect_from_terminal(mtw);
    *out = dirty;
    return dirty.width > 0 && dirty.height > 0;
}

int mac_termwin_smoke(void)
{
    Conf *conf;
    struct unicode_data ucsdata;
    Terminal *term;
    MacTermWin *mtw;
    const rgb *palette;
    static const char test_data[] = "hello\r\n";

    conf = conf_new();
    do_defaults(NULL, conf);
    init_ucs_generic(conf, &ucsdata);

    mtw = mac_termwin_new();
    mac_termwin_set_conf(mtw, conf);

    term = term_init(conf, &ucsdata, mac_termwin_get_termwin(mtw));
    mac_termwin_set_terminal(mtw, term);
    term_size(term, 24, 80, 1000);
    term->ldisc = NULL;

    term_data(term, test_data, sizeof(test_data) - 1);
    term_update(term);

    palette = mac_termwin_get_colours(mtw);
    if (palette[OSC4_COLOUR_fg].r == 0 &&
        palette[OSC4_COLOUR_fg].g == 0 &&
        palette[OSC4_COLOUR_fg].b == 0)
        return 1;

    term_free(term);
    mac_termwin_free(mtw);
    conf_free(conf);
    return 0;
}
