/*
 * macos/platform/osxkeys.h — macOS key translation helpers (Phase 4.5).
 *
 * Used by putty-bridge-termwin to format terminal key sequences via the
 * shared PuTTY terminal key-encoding functions.
 */

#ifndef PUTTY_MACOS_PLATFORM_OSXKEYS_H
#define PUTTY_MACOS_PLATFORM_OSXKEYS_H

#include <stdbool.h>
#include <stddef.h>

#include "putty.h"

/** Return-key encoding (CR / CRLF / special Return). */
int osxkeys_format_return(
    Terminal *term, char *buf, size_t buflen, bool *special_out);

/** Arrow / keypad arrow keys (xkey is 'A'..'D', 'G', etc.). */
int osxkeys_format_arrow(
    Terminal *term, int xkey, bool shift, bool ctrl, bool alt,
    char *buf, size_t buflen, bool *consumed_alt_out);

/** Function keys (F1 = 1, …). */
int osxkeys_format_function(
    Terminal *term, int fkey_number, bool shift, bool ctrl, bool alt,
    char *buf, size_t buflen, bool *consumed_alt_out);

int osxkeys_format_small_keypad(
    Terminal *term, SmallKeypadKey key, bool shift, bool ctrl, bool alt,
    char *buf, size_t buflen, bool *consumed_alt_out);

/**
 * Backspace / Delete (macOS keycode 0x33). Honours CONF_bksp_is_delete;
 * Shift inverts the configured byte (same as GTK/Windows).
 * Writes one byte into buf; returns length (1) or 0.
 */
int osxkeys_format_backspace(
    Terminal *term, bool shift, char *buf, size_t buflen, bool *special_out);

/** Apply PuTTY-style Ctrl masking to a 7-bit character. */
unsigned char osxkeys_apply_ctrl(unsigned char c);

#endif /* PUTTY_MACOS_PLATFORM_OSXKEYS_H */
