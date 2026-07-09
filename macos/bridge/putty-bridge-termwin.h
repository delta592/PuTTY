/*
 * putty-bridge-termwin.h — Swift-facing MacTermWin / TerminalView API (Phase 4.2+).
 *
 * Import through the PuttyBridge clang module. Do not include termwin.h from
 * Swift.
 */

#ifndef PUTTY_MACOS_PUTTY_BRIDGE_TERMWIN_H
#define PUTTY_MACOS_PUTTY_BRIDGE_TERMWIN_H

#include <stddef.h>
#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct PuttyBridgeTermWin PuttyBridgeTermWin;

typedef struct PuttyBridgeTermWinRect {
    double x, y, width, height;
} PuttyBridgeTermWinRect;

typedef struct PuttyBridgeOptionalRgb {
    bool enabled;
    uint8_t r, g, b;
} PuttyBridgeOptionalRgb;

typedef struct PuttyBridgeTrueColour {
    PuttyBridgeOptionalRgb fg;
    PuttyBridgeOptionalRgb bg;
} PuttyBridgeTrueColour;

/** Cell-space draw parameters forwarded from MacTermWin. */
typedef struct PuttyBridgeTermWinDrawParams {
    int32_t x, y;
    const wchar_t *text;
    int32_t len;
    uint32_t attr;
    int32_t lattr;
    PuttyBridgeTrueColour truecolour;
} PuttyBridgeTermWinDrawParams;

typedef struct PuttyBridgeTermWinCallbacks {
    bool (*setup_draw_ctx)(void *ctx);
    void (*free_draw_ctx)(void *ctx);
    void (*draw_text)(void *ctx, const PuttyBridgeTermWinDrawParams *params);
    void (*draw_cursor)(void *ctx, const PuttyBridgeTermWinDrawParams *params);
    void (*draw_trust_sigil)(void *ctx, int32_t x, int32_t y);
    void (*request_redraw)(void *ctx, PuttyBridgeTermWinRect dirty);
    int32_t (*char_width)(void *ctx, int32_t uc);
} PuttyBridgeTermWinCallbacks;

#define PUTTY_BRIDGE_ATTR_FGMASK      0x000001FFU
#define PUTTY_BRIDGE_ATTR_BGMASK      0x0003FE00U
#define PUTTY_BRIDGE_ATTR_FGSHIFT     0
#define PUTTY_BRIDGE_ATTR_BGSHIFT     9
#define PUTTY_BRIDGE_ATTR_WIDE        0x00400000U
#define PUTTY_BRIDGE_ATTR_REVERSE     0x00040000U
#define PUTTY_BRIDGE_ATTR_BOLD        0x00080000U
#define PUTTY_BRIDGE_ATTR_BLINK       0x00100000U
#define PUTTY_BRIDGE_ATTR_UNDER       0x00800000U
#define PUTTY_BRIDGE_ATTR_DIM         0x01000000U
#define PUTTY_BRIDGE_ATTR_STRIKE      0x02000000U
#define PUTTY_BRIDGE_ATTR_ACTCURS     0x40000000U
#define PUTTY_BRIDGE_ATTR_PASCURS     0x20000000U
#define PUTTY_BRIDGE_ATTR_RIGHTCURS   0x10000000U
#define PUTTY_BRIDGE_ATTR_COMBINING   0x80000000U

#define PUTTY_BRIDGE_LATTR_NORM       0x00000000
#define PUTTY_BRIDGE_LATTR_WIDE       0x00000001
#define PUTTY_BRIDGE_LATTR_TOP        0x00000002
#define PUTTY_BRIDGE_LATTR_BOT        0x00000003
#define PUTTY_BRIDGE_LATTR_MODE       0x00000003

#define PUTTY_BRIDGE_CURSOR_BLOCK           0
#define PUTTY_BRIDGE_CURSOR_UNDERLINE       1
#define PUTTY_BRIDGE_CURSOR_VERTICAL_LINE   2

#define PUTTY_BRIDGE_BOLD_STYLE_FONT        1
#define PUTTY_BRIDGE_BOLD_STYLE_COLOUR      2

#define PUTTY_BRIDGE_OSC4_CURSOR_FG   260
#define PUTTY_BRIDGE_OSC4_CURSOR_BG   261

PuttyBridgeTermWin *putty_bridge_termwin_new(void);
void putty_bridge_termwin_free(PuttyBridgeTermWin *btw);

void putty_bridge_termwin_set_callbacks(
    PuttyBridgeTermWin *btw,
    const PuttyBridgeTermWinCallbacks *callbacks,
    void *view_ctx);

bool putty_bridge_termwin_init_demo(PuttyBridgeTermWin *btw);

void putty_bridge_termwin_set_backing_scale(PuttyBridgeTermWin *btw, double scale);
double putty_bridge_termwin_get_backing_scale(const PuttyBridgeTermWin *btw);

void putty_bridge_termwin_set_font_metrics(
    PuttyBridgeTermWin *btw, double cell_width_pt, double cell_height_pt,
    double ascent_pt, double descent_pt);

double putty_bridge_termwin_cell_width_pt(const PuttyBridgeTermWin *btw);
double putty_bridge_termwin_cell_height_pt(const PuttyBridgeTermWin *btw);
double putty_bridge_termwin_ascent_pt(const PuttyBridgeTermWin *btw);

void putty_bridge_termwin_resize_to_view(
    PuttyBridgeTermWin *btw, double view_width_pt, double view_height_pt);

void putty_bridge_termwin_paint(
    PuttyBridgeTermWin *btw, int32_t left, int32_t top,
    int32_t right, int32_t bottom);

bool putty_bridge_termwin_palette_colour(
    const PuttyBridgeTermWin *btw, uint32_t index,
    uint8_t *r, uint8_t *g, uint8_t *b);

int32_t putty_bridge_termwin_cols(const PuttyBridgeTermWin *btw);
int32_t putty_bridge_termwin_rows(const PuttyBridgeTermWin *btw);
int32_t putty_bridge_termwin_cursor_type(const PuttyBridgeTermWin *btw);
int32_t putty_bridge_termwin_bold_style(const PuttyBridgeTermWin *btw);

#ifdef __cplusplus
}
#endif

#endif /* PUTTY_MACOS_PUTTY_BRIDGE_TERMWIN_H */
