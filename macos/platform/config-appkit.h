/*
 * macos/platform/config-appkit.h — AppKit controlbox renderer (Phase 6.1).
 *
 * Walks the portable struct controlbox from config.c and maps CTRL_*
 * types to AppKit widgets. Full settings-window chrome (toolbar, Apply
 * wiring, launch flow) is Phase 6.2+.
 *
 * Note: dialog.h has no include guards; callers that need dlgcontrol /
 * controlset types should #include "dialog.h" once themselves.
 */

#ifndef PUTTY_MACOS_PLATFORM_CONFIG_APPKIT_H
#define PUTTY_MACOS_PLATFORM_CONFIG_APPKIT_H

#include "putty.h"

#ifdef __cplusplus
extern "C" {
#endif

struct controlbox;
struct controlset;
struct dlgparam;

/**
 * Build the portable + macOS controlbox for Conf, without creating UI.
 * Caller must ctrl_free_box() the result.
 */
struct controlbox *mac_config_build_controlbox(
    Conf *conf, bool midsession, int protcfginfo);

/**
 * Create an AppKit configuration window that renders ctrlbox panels.
 * Returns an opaque MacConfigBox * (also stored for dlg_* lookups).
 * The window is shown; when the dialog ends, `after` is called.
 */
typedef struct MacConfigBox MacConfigBox;

MacConfigBox *mac_config_create_box(
    const char *title, Conf *conf, bool midsession, int protcfginfo,
    post_dialog_fn_t after, void *afterctx);

/** Destroy a config box created by mac_config_create_box (if still open). */
void mac_config_box_free(MacConfigBox *box);

/** NSView * for a single controlset panel (testing / embed). */
void *mac_config_layout_controlset(
    struct dlgparam *dp, struct controlset *s);

/**
 * Headless smoke: build controlbox, instantiate widgets off-screen,
 * exercise dlg_* get/set for representative CTRL_* types. Returns 0 on OK.
 */
int mac_config_controlbox_smoke(void);

#ifdef __cplusplus
}
#endif

#endif /* PUTTY_MACOS_PLATFORM_CONFIG_APPKIT_H */
