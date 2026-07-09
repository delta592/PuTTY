/*
 * macos/platform/termwin.h — MacTermWin TermWin implementation (Phase 4.1).
 *
 * MacTermWin is the AppKit terminal window adapter: it implements the full
 * TermWinVtable and forwards drawing, clipboard, and window chrome to Swift
 * via MacTermWinCallbacks. Swift owns TerminalView; this struct stores only a
 * weak void *view_ctx (never retained).
 */

#ifndef PUTTY_MACOS_PLATFORM_TERMWIN_H
#define PUTTY_MACOS_PLATFORM_TERMWIN_H

#include "putty.h"
#include "terminal.h"

#ifdef __cplusplus
extern "C" {
#endif

/** Pixel-space dirty region in terminal-view coordinates (points). */
typedef struct MacTermWinRect {
    double x, y, width, height;
} MacTermWinRect;

/** Parameters for draw_text / draw_cursor callbacks (cell coordinates). */
typedef struct MacTermWinDrawParams {
    int x, y;
    wchar_t *text;
    int len;
    unsigned long attr;
    int lattr;
    truecolour tc;
} MacTermWinDrawParams;

/**
 * Optional Swift / AppKit callbacks. Any NULL entry is a no-op on the view
 * side; palette and font metrics remain in C until Phase 4.3 wires Core Text.
 */
typedef struct MacTermWinCallbacks {
    bool (*setup_draw_ctx)(void *ctx);
    void (*free_draw_ctx)(void *ctx);
    void (*draw_text)(void *ctx, const MacTermWinDrawParams *params);
    void (*draw_cursor)(void *ctx, const MacTermWinDrawParams *params);
    void (*draw_trust_sigil)(void *ctx, int x, int y);
    int (*char_width)(void *ctx, int uc);
    void (*set_cursor_pos)(void *ctx, int x, int y);
    void (*set_raw_mouse_mode)(void *ctx, bool enable);
    void (*set_raw_mouse_mode_pointer)(void *ctx, bool enable);
    void (*set_scrollbar)(void *ctx, int total, int start, int page);
    void (*bell)(void *ctx, int mode);
    void (*clip_write)(
        void *ctx, int clipboard, wchar_t *text, int *attrs,
        truecolour *colours, int len, bool must_deselect);
    void (*clip_request_paste)(void *ctx, int clipboard);
    void (*request_redraw)(void *ctx, MacTermWinRect dirty);
    void (*request_resize)(void *ctx, int cols, int rows);
    void (*set_title)(void *ctx, const char *title, int codepage);
    void (*set_icon_title)(void *ctx, const char *title, int codepage);
    void (*set_minimised)(void *ctx, bool minimised);
    void (*set_maximised)(void *ctx, bool maximised);
    void (*move)(void *ctx, int x, int y);
    void (*set_zorder)(void *ctx, bool top);
} MacTermWinCallbacks;

struct MacTermWin {
    TermWin termwin;

    void *view_ctx;
    MacTermWinCallbacks callbacks;

    Terminal *term;
    Backend *backend;
    Conf *conf;

    bool draw_ctx_active;

    double cell_width_pt;
    double cell_height_pt;
    double ascent_pt;
    double descent_pt;

    double backing_scale;

    rgb colours[OSC4_NCOLOURS];

    int cursor_type;
    int bold_style;

    bool send_raw_mouse;
    bool pointer_indicates_raw_mouse;

    int caret_x, caret_y;

    int scroll_total, scroll_start, scroll_page;
};

MacTermWin *mac_termwin_new(void);
void mac_termwin_free(MacTermWin *mtw);

TermWin *mac_termwin_get_termwin(MacTermWin *mtw);
MacTermWin *mac_termwin_from_termwin(TermWin *tw);

void mac_termwin_set_callbacks(
    MacTermWin *mtw, const MacTermWinCallbacks *callbacks, void *view_ctx);
void mac_termwin_set_terminal(MacTermWin *mtw, Terminal *term);
void mac_termwin_set_backend(MacTermWin *mtw, Backend *backend);
void mac_termwin_set_conf(MacTermWin *mtw, Conf *conf);
void mac_termwin_cache_conf_values(MacTermWin *mtw);

void mac_termwin_set_backing_scale(MacTermWin *mtw, double scale);
double mac_termwin_get_backing_scale(const MacTermWin *mtw);

void mac_termwin_set_font_metrics(
    MacTermWin *mtw, double cell_width_pt, double cell_height_pt,
    double ascent_pt, double descent_pt);

const rgb *mac_termwin_get_colours(const MacTermWin *mtw);

/** Phase 4.1 smoke test: term_init + term_update through MacTermWin. */
int mac_termwin_smoke(void);

#ifdef __cplusplus
}
#endif

#endif /* PUTTY_MACOS_PLATFORM_TERMWIN_H */
