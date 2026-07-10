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

/*
 * Forward declaration only — putty-bridge.h includes this header, so we must
 * not include putty-bridge.h here (circular). Standalone includers (e.g. the
 * termwin perf driver) need PuttyConf for putty_bridge_termwin_open().
 */
#ifndef PUTTY_CONF_TYPEDEF_DEFINED
#define PUTTY_CONF_TYPEDEF_DEFINED
typedef struct PuttyConf PuttyConf;
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
    void (*set_cursor_pos)(void *ctx, int32_t x, int32_t y);
    void (*set_raw_mouse_mode)(void *ctx, bool enable);
    void (*set_raw_mouse_mode_pointer)(void *ctx, bool enable);
    void (*clip_write)(
        void *ctx, int32_t clipboard, const wchar_t *text, int32_t len,
        bool must_deselect);
    void (*clip_request_paste)(void *ctx, int32_t clipboard);
    void (*set_scrollbar)(
        void *ctx, int32_t total, int32_t start, int32_t page);
    void (*request_resize)(void *ctx, int32_t cols, int32_t rows);
    void (*bell)(void *ctx, int32_t mode);
    void (*set_title)(void *ctx, const char *title_utf8);
    void (*set_icon_title)(void *ctx, const char *title_utf8);
    /** Fired after mid-session Change Settings Apply (font, colours, …). */
    void (*settings_changed)(void *ctx);
} PuttyBridgeTermWinCallbacks;

#define PUTTY_BRIDGE_BELL_DISABLED    0
#define PUTTY_BRIDGE_BELL_DEFAULT     1
#define PUTTY_BRIDGE_BELL_VISUAL      2
#define PUTTY_BRIDGE_BELL_WAVEFILE    3
#define PUTTY_BRIDGE_BELL_PCSPEAKER     4

#define PUTTY_BRIDGE_RESIZE_TERM      0
#define PUTTY_BRIDGE_RESIZE_DISABLED  1
#define PUTTY_BRIDGE_RESIZE_FONT      2
#define PUTTY_BRIDGE_RESIZE_EITHER    3

/* Must match ATTR_* in putty.h — wrong bits swap colours / miss bold. */
#define PUTTY_BRIDGE_ATTR_FGMASK      0x000001FFU
#define PUTTY_BRIDGE_ATTR_BGMASK      0x0003FE00U
#define PUTTY_BRIDGE_ATTR_FGSHIFT     0
#define PUTTY_BRIDGE_ATTR_BGSHIFT     9
#define PUTTY_BRIDGE_ATTR_BOLD        0x00040000U
#define PUTTY_BRIDGE_ATTR_UNDER       0x00080000U
#define PUTTY_BRIDGE_ATTR_REVERSE     0x00100000U
#define PUTTY_BRIDGE_ATTR_BLINK       0x00200000U
#define PUTTY_BRIDGE_ATTR_WIDE        0x00400000U
#define PUTTY_BRIDGE_ATTR_NARROW      0x00800000U
#define PUTTY_BRIDGE_ATTR_DIM         0x01000000U
#define PUTTY_BRIDGE_ATTR_STRIKE      0x02000000U
#define PUTTY_BRIDGE_ATTR_RIGHTCURS   0x10000000U
#define PUTTY_BRIDGE_ATTR_PASCURS     0x20000000U
#define PUTTY_BRIDGE_ATTR_ACTCURS     0x40000000U
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

/* Mouse_Button / Mouse_Action (putty.h). */
#define PUTTY_BRIDGE_SKK_HOME           0
#define PUTTY_BRIDGE_SKK_END            1
#define PUTTY_BRIDGE_SKK_INSERT         2
#define PUTTY_BRIDGE_SKK_DELETE         3
#define PUTTY_BRIDGE_SKK_PGUP           4
#define PUTTY_BRIDGE_SKK_PGDN           5

#define PUTTY_BRIDGE_MBT_LEFT           1
#define PUTTY_BRIDGE_MBT_MIDDLE         2
#define PUTTY_BRIDGE_MBT_RIGHT          3
#define PUTTY_BRIDGE_MBT_WHEEL_UP       7
#define PUTTY_BRIDGE_MBT_WHEEL_DOWN     8
#define PUTTY_BRIDGE_MBT_WHEEL_LEFT     9
#define PUTTY_BRIDGE_MBT_WHEEL_RIGHT    10

#define PUTTY_BRIDGE_MA_CLICK           1
#define PUTTY_BRIDGE_MA_2CLK            2
#define PUTTY_BRIDGE_MA_3CLK            3
#define PUTTY_BRIDGE_MA_DRAG            4
#define PUTTY_BRIDGE_MA_RELEASE         5
#define PUTTY_BRIDGE_MA_MOVE            6

/* CONF_mouse_is_xterm / putty.h mouse-button assignments */
#define PUTTY_BRIDGE_MOUSE_COMPROMISE   0
#define PUTTY_BRIDGE_MOUSE_XTERM        1
#define PUTTY_BRIDGE_MOUSE_WINDOWS      2

/* Clipboard IDs (putty.h / platform.h). */
#define PUTTY_BRIDGE_CLIP_LOCAL         1
#define PUTTY_BRIDGE_CLIP_CLIPBOARD     2
#define PUTTY_BRIDGE_CLIP_CUSTOM_1      3

PuttyBridgeTermWin *putty_bridge_termwin_new(void);
void putty_bridge_termwin_free(PuttyBridgeTermWin *btw);

void putty_bridge_termwin_set_callbacks(
    PuttyBridgeTermWin *btw,
    const PuttyBridgeTermWinCallbacks *callbacks,
    void *view_ctx);

bool putty_bridge_termwin_init_demo(PuttyBridgeTermWin *btw);

/** Phase 5.2: MacGuiSeat-backed session wired to TerminalView callbacks. */
bool putty_bridge_termwin_init_session(PuttyBridgeTermWin *btw);

/**
 * Open a MacGuiSeat-backed session using conf (copied). When connect is true
 * and conf is launchable, starts the backend; otherwise local echo is used.
 */
bool putty_bridge_termwin_open(
    PuttyBridgeTermWin *btw, const PuttyConf *conf, bool connect);

bool putty_bridge_termwin_session_is_active(const PuttyBridgeTermWin *btw);
bool putty_bridge_termwin_should_warn_on_close(const PuttyBridgeTermWin *btw);
/** Caller must free with putty_bridge_termwin_free_close_warn_text(). */
char *putty_bridge_termwin_close_warn_text(const PuttyBridgeTermWin *btw);
void putty_bridge_termwin_free_close_warn_text(char *text);

/** One entry from backend_get_specials() (Phase 5.6). */
typedef struct PuttyBridgeSessionSpecial {
    const char *name;
    int32_t code;
    int32_t arg;
} PuttyBridgeSessionSpecial;

typedef void (*PuttyBridgeSpecialsMenuCallback)(void *ctx);

void putty_bridge_termwin_set_specials_menu_callback(
    PuttyBridgeTermWin *btw,
    PuttyBridgeSpecialsMenuCallback callback,
    void *ctx);

/* ---------------------------------------------------------------------- */
/* Event log (Phase 6.4) */

typedef void (*PuttyBridgeEventLogCallback)(void *ctx);

void putty_bridge_termwin_set_eventlog_callback(
    PuttyBridgeTermWin *btw,
    PuttyBridgeEventLogCallback callback,
    void *ctx);

/** Number of stored Event Log lines (initial + circular ring). */
size_t putty_bridge_termwin_eventlog_count(const PuttyBridgeTermWin *btw);

/**
 * Copy Event Log line at index into buf (NUL-terminated). Returns false if
 * index is out of range. Lines are "YYYY-MM-DD HH:MM:SS\\tmessage".
 */
bool putty_bridge_termwin_eventlog_line(
    const PuttyBridgeTermWin *btw, size_t index, char *buf, size_t buflen);

/** Append a synthetic line (smoke / tests). */
void putty_bridge_termwin_eventlog_append_test(
    PuttyBridgeTermWin *btw, const char *message);

/** Headless smoke for Event Log buffer. Returns 0 on success. */
int putty_bridge_termwin_eventlog_smoke(void);

/** True when the active backend exposes a non-empty specials list. */
bool putty_bridge_termwin_has_specials(const PuttyBridgeTermWin *btw);

/**
 * Copy specials from the session backend into out[0..max_out-1], stopping when
 * the top-level SS_EXITMENU is consumed. Returns 0 when there are no specials.
 */
size_t putty_bridge_termwin_copy_specials(
    const PuttyBridgeTermWin *btw,
    PuttyBridgeSessionSpecial *out,
    size_t max_out);

void putty_bridge_termwin_send_special(
    PuttyBridgeTermWin *btw, int32_t code, int32_t arg);

int32_t putty_bridge_special_code_sep(void);
int32_t putty_bridge_special_code_submenu(void);
int32_t putty_bridge_special_code_exitmenu(void);

void putty_bridge_termwin_set_backing_scale(PuttyBridgeTermWin *btw, double scale);
double putty_bridge_termwin_get_backing_scale(const PuttyBridgeTermWin *btw);

void putty_bridge_termwin_set_font_metrics(
    PuttyBridgeTermWin *btw, double cell_width_pt, double cell_height_pt,
    double ascent_pt, double descent_pt);

/**
 * Terminal font from Conf (mac:PostScriptName:pointSize). Pointer owned by
 * the termwin Conf; valid until the next Conf mutation/reconfigure.
 */
const char *putty_bridge_termwin_font_spec(const PuttyBridgeTermWin *btw);

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

bool putty_bridge_termwin_resize_grid(
    PuttyBridgeTermWin *btw, int32_t cols, int32_t rows);
size_t putty_bridge_termwin_feed(
    PuttyBridgeTermWin *btw, const void *data, size_t len);
bool putty_bridge_termwin_compute_dirty_rect(
    PuttyBridgeTermWin *btw, PuttyBridgeTermWinRect *out);

/**
 * Phase 4.4 perf gate: full-screen term_paint benchmark at 120×80.
 * Returns 0 when mean frame time is below budget_ms (60 fps ⇒ 16.67).
 * Set PUTTY_BRIDGE_PERF_SKIP=1 to skip (returns 0).
 */
int putty_bridge_termwin_perf_paint_benchmark(
    PuttyBridgeTermWin *btw, int frames, double budget_ms);

/* Phase 4.5 — keyboard / mouse / selection input. */
void putty_bridge_termwin_key_bytes(
    PuttyBridgeTermWin *btw, int32_t codepage, const void *data, int32_t len);
void putty_bridge_termwin_key_special(
    PuttyBridgeTermWin *btw, const char *nul_terminated);
void putty_bridge_termwin_key_wide(
    PuttyBridgeTermWin *btw, const wchar_t *data, int32_t len);

int32_t putty_bridge_termwin_format_return(
    PuttyBridgeTermWin *btw, char *buf, int32_t buflen, bool *special_out);
int32_t putty_bridge_termwin_format_arrow(
    PuttyBridgeTermWin *btw, int32_t xkey, bool shift, bool ctrl, bool alt,
    char *buf, int32_t buflen, bool *consumed_alt_out);
int32_t putty_bridge_termwin_format_function(
    PuttyBridgeTermWin *btw, int32_t fkey_number, bool shift, bool ctrl,
    bool alt, char *buf, int32_t buflen, bool *consumed_alt_out);
int32_t putty_bridge_termwin_format_small_keypad(
    PuttyBridgeTermWin *btw, int32_t key, bool shift, bool ctrl, bool alt,
    char *buf, int32_t buflen, bool *consumed_alt_out);
int32_t putty_bridge_termwin_format_backspace(
    PuttyBridgeTermWin *btw, bool shift, char *buf, int32_t buflen,
    bool *special_out);
uint8_t putty_bridge_termwin_apply_ctrl(uint8_t c);

void putty_bridge_termwin_mouse(
    PuttyBridgeTermWin *btw, int32_t button_raw, int32_t action,
    int32_t cell_x, int32_t cell_y, bool shift, bool ctrl, bool alt);
void putty_bridge_termwin_scroll_lines(PuttyBridgeTermWin *btw, int32_t lines);
void putty_bridge_termwin_scroll_to(PuttyBridgeTermWin *btw, int32_t position);

void putty_bridge_termwin_request_resize_completed(PuttyBridgeTermWin *btw);
int32_t putty_bridge_termwin_resize_action(const PuttyBridgeTermWin *btw);
bool putty_bridge_termwin_scrollbar_enabled(const PuttyBridgeTermWin *btw);
void putty_bridge_termwin_view_size_for_grid(
    const PuttyBridgeTermWin *btw, int32_t cols, int32_t rows,
    double *width_pt, double *height_pt);
void putty_bridge_termwin_apply_live_resize(
    PuttyBridgeTermWin *btw, double view_width_pt, double view_height_pt);
void putty_bridge_termwin_scrollbar_state(
    const PuttyBridgeTermWin *btw,
    int32_t *total, int32_t *start, int32_t *page);

bool putty_bridge_termwin_raw_mouse_active(const PuttyBridgeTermWin *btw);
bool putty_bridge_termwin_pointer_indicates_raw_mouse(
    const PuttyBridgeTermWin *btw);
bool putty_bridge_termwin_mouse_override_shift(const PuttyBridgeTermWin *btw);
/** CONF_mouse_is_xterm: COMPROMISE / XTERM / WINDOWS. */
int32_t putty_bridge_termwin_mouse_buttons_mode(const PuttyBridgeTermWin *btw);
/** True when right-click should open the context menu (not paste/extend). */
bool putty_bridge_termwin_right_click_shows_menu(
    const PuttyBridgeTermWin *btw, bool control);
void putty_bridge_termwin_cancel_selection_drag(PuttyBridgeTermWin *btw);

void putty_bridge_termwin_copy_selection(PuttyBridgeTermWin *btw);
void putty_bridge_termwin_copy_all(PuttyBridgeTermWin *btw);
void putty_bridge_termwin_select_all(PuttyBridgeTermWin *btw);
void putty_bridge_termwin_request_paste(
    PuttyBridgeTermWin *btw, int32_t clipboard);
void putty_bridge_termwin_paste_text(
    PuttyBridgeTermWin *btw, const wchar_t *data, int32_t len);

void putty_bridge_termwin_setup_clipboards(PuttyBridgeTermWin *btw);
void putty_bridge_termwin_lost_clipboard_ownership(
    PuttyBridgeTermWin *btw, int32_t clipboard);
bool putty_bridge_termwin_mouse_autocopy_enabled(
    const PuttyBridgeTermWin *btw);
int32_t putty_bridge_termwin_mouse_select_clipboard_count(
    const PuttyBridgeTermWin *btw);

/** Smoke test: clipboard setup matches Conf (HIG autocopy default). Returns 0 on success. */
int putty_bridge_termwin_clipboard_smoke(void);

/** Smoke test: feed keys and mouse events to demo terminal. Returns 0 on success. */
int putty_bridge_termwin_input_smoke(void);

/** Smoke test: scrollbar state, scroll-to, resize policy. Returns 0 on success. */
int putty_bridge_termwin_scroll_resize_smoke(void);

bool putty_bridge_termwin_win_name_always(const PuttyBridgeTermWin *btw);
bool putty_bridge_termwin_bell_wavefile_path(
    const PuttyBridgeTermWin *btw, char *buf, size_t buflen);

/** Smoke test: bell and title callbacks / title decode. Returns 0 on success. */
int putty_bridge_termwin_bell_title_smoke(void);

/**
 * Exit gate: local echo through ldisc, grid sanity, paint + perf budget.
 * Returns 0 on success.
 */
int putty_bridge_termwin_exit_smoke(void);

/** Exit gate: seat.output path through MacGuiSeat. Returns 0 on success. */
int putty_bridge_termwin_seat_output_exit_smoke(void);

/** Exit gate: security dialog wiring through MacGuiSeat. Returns 0 on success. */
int putty_bridge_termwin_seat_dialogs_exit_smoke(void);

/** Exit gate: AppKit event loop + session init. Returns 0 on success. */
int putty_bridge_termwin_eventloop_exit_smoke(void);

/** Exit gate: session window controller wiring. Returns 0 on success. */
int putty_bridge_termwin_window_exit_smoke(void);

/** Exit gate: specials menu bridge wiring. Returns 0 on success. */
int putty_bridge_termwin_specials_exit_smoke(void);

/** True when the session terminal buffer contains non-blank cells. */
bool putty_bridge_termwin_terminal_has_visible_text(const PuttyBridgeTermWin *btw);

/**
 * Open mid-session Change Settings for this termwin (Phase 6.2).
 * Edits a Conf copy; on Apply, reconfigures the live seat/terminal/backend.
 * Returns false if the session is not ready for reconfiguration.
 */
bool putty_bridge_termwin_change_settings(PuttyBridgeTermWin *btw);

/**
 * Session → Duplicate Session: open a new window with a copy of this
 * termwin's Conf. No-op if conf is missing or not launchable.
 */
void putty_bridge_launch_duplicate_session(PuttyBridgeTermWin *btw);

/**
 * True when Restart Session is available (backend gone after remote exit).
 */
bool putty_bridge_termwin_can_restart(const PuttyBridgeTermWin *btw);

/**
 * Restart the session after remote exit (Phase 7.1). Returns false if
 * restart is not available or backend start fails.
 */
bool putty_bridge_termwin_restart_session(PuttyBridgeTermWin *btw);

/**
 * Called when the remote session exits (or connection is destroyed) so
 * Swift can enable Session → Restart Session, and optionally close the
 * window when CloseOnExit says so.
 */
typedef void (*PuttyBridgeRemoteExitCallback)(
    void *ctx, int exitcode, bool close_window);

void putty_bridge_termwin_set_remote_exit_callback(
    PuttyBridgeTermWin *btw,
    PuttyBridgeRemoteExitCallback callback,
    void *ctx);

/** Attach terminal window for sheet-modal security prompts (NSWindow *). */
void putty_bridge_set_parent_window(void *nswindow);

#ifdef __cplusplus
}
#endif

#endif /* PUTTY_MACOS_PUTTY_BRIDGE_TERMWIN_H */
