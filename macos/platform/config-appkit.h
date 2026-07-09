/*
 * macos/platform/config-appkit.h — AppKit controlbox renderer (Phase 6.1–6.2).
 *
 * Walks the portable struct controlbox from config.c and maps CTRL_*
 * types to AppKit widgets. Phase 6.2 adds toolbar/sidebar UX, Conf
 * backup on Cancel, Restore Defaults / Duplicate, and mid-session
 * reconfiguration entry points.
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

/** Access the controlbox owned by a live Mac dlgparam (for platform handlers). */
struct controlbox *mac_config_dlg_ctrlbox(struct dlgparam *dp);

/**
 * Create an AppKit configuration window that renders ctrlbox panels.
 * Returns an opaque MacConfigBox *. On Cancel, Conf is restored from a
 * backup taken at open (Windows do_reconfig parity). On Apply/Open
 * (retval > 0), Conf keeps the edited values.
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
 * Mid-session Change Settings: edit a copy of conf, then call after(ctx, 1)
 * with the edited Conf still in *conf_inout on success. On cancel, conf is
 * unchanged. protcfginfo comes from backend_cfg_info().
 */
void mac_config_change_settings(
    Conf **conf_inout, int protcfginfo,
    post_dialog_fn_t after, void *afterctx);

/**
 * Headless smoke: build controlbox, instantiate widgets off-screen,
 * exercise dlg_* get/set and Phase 6.2 UX helpers. Returns 0 on OK.
 */
int mac_config_controlbox_smoke(void);

/** Phase 6.2 smoke: midsession box, restore-defaults, Conf cancel backup. */
int mac_config_settings_ux_smoke(void);

#ifdef __cplusplus
}
#endif

#endif /* PUTTY_MACOS_PLATFORM_CONFIG_APPKIT_H */
