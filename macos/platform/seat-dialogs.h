/*
 * macos/platform/seat-dialogs.h — AppKit security / error dialogs (Phase 5.3).
 */

#ifndef PUTTY_MACOS_PLATFORM_SEAT_DIALOGS_H
#define PUTTY_MACOS_PLATFORM_SEAT_DIALOGS_H

#include "putty.h"

#ifdef __cplusplus
extern "C" {
#endif

/** NSWindow * for sheet attachment; NULL uses application-modal alerts. */
void mac_gui_dialogs_set_parent_window(void *nswindow);
void *mac_gui_dialogs_get_parent_window(void);

void mac_gui_dialogs_ensure_app(void);

const SeatDialogPromptDescriptions *mac_seat_prompt_descriptions(Seat *seat);

SeatPromptResult mac_seat_confirm_ssh_host_key(
    Seat *seat, const char *host, int port, const char *keytype,
    char *keystr, SeatDialogText *text, HelpCtx helpctx,
    void (*callback)(void *ctx, SeatPromptResult result), void *ctx);

SeatPromptResult mac_seat_confirm_weak_crypto_primitive(
    Seat *seat, SeatDialogText *text,
    void (*callback)(void *ctx, SeatPromptResult result), void *ctx);

SeatPromptResult mac_seat_confirm_weak_cached_hostkey(
    Seat *seat, SeatDialogText *text,
    void (*callback)(void *ctx, SeatPromptResult result), void *ctx);

SeatPromptResult mac_seat_get_userpass_input_dialog(prompts_t *p);

void mac_seat_show_connection_fatal(
    const char *title, const char *msg, HelpCtx helpctx);
void mac_seat_show_nonfatal(const char *title, const char *msg, HelpCtx helpctx);

/** Phase 5.3 smoke: prompt description strings (no GUI). Returns 0 on success. */
int mac_gui_seat_dialogs_smoke(void);

#ifdef __cplusplus
}
#endif

#endif /* PUTTY_MACOS_PLATFORM_SEAT_DIALOGS_H */
