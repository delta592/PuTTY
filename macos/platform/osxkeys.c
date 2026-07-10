/*
 * macos/platform/osxkeys.c — macOS key translation helpers (Phase 4.5).
 */

#include "osxkeys.h"

#include "terminal.h"

int osxkeys_format_return(
    Terminal *term, char *buf, size_t buflen, bool *special_out)
{
    if (!term || !buf || buflen < 2 || !special_out)
        return 0;

    if (term->cr_lf_return) {
        if (buflen < 3)
            return 0;
        buf[0] = '\015';
        buf[1] = '\012';
        *special_out = false;
        return 2;
    }

    buf[0] = '\015';
    *special_out = true;
    return 1;
}

int osxkeys_format_arrow(
    Terminal *term, int xkey, bool shift, bool ctrl, bool alt,
    char *buf, size_t buflen, bool *consumed_alt_out)
{
    if (!term || !buf || buflen < 16)
        return 0;

    if (consumed_alt_out)
        *consumed_alt_out = false;

    return format_arrow_key(buf, term, xkey, shift, ctrl, alt, consumed_alt_out);
}

int osxkeys_format_function(
    Terminal *term, int fkey_number, bool shift, bool ctrl, bool alt,
    char *buf, size_t buflen, bool *consumed_alt_out)
{
    if (!term || !buf || buflen < 32 || fkey_number < 1)
        return 0;

    if (consumed_alt_out)
        *consumed_alt_out = false;

    return format_function_key(
        buf, term, fkey_number, shift, ctrl, alt, consumed_alt_out);
}

int osxkeys_format_small_keypad(
    Terminal *term, SmallKeypadKey key, bool shift, bool ctrl, bool alt,
    char *buf, size_t buflen, bool *consumed_alt_out)
{
    if (!term || !buf || buflen < 16)
        return 0;

    if (consumed_alt_out)
        *consumed_alt_out = false;

    return format_small_keypad_key(
        buf, term, key, shift, ctrl, alt, consumed_alt_out);
}

int osxkeys_format_backspace(
    Terminal *term, bool shift, char *buf, size_t buflen, bool *special_out)
{
    bool delete_is_default;

    if (!term || !buf || buflen < 2)
        return 0;

    delete_is_default = term->bksp_is_delete;
    if (shift)
        delete_is_default = !delete_is_default;

    buf[0] = delete_is_default ? '\x7F' : '\x08';
    if (special_out)
        *special_out = true;
    return 1;
}

unsigned char osxkeys_apply_ctrl(unsigned char c)
{
    if (c >= '3' && c <= '7')
        return (unsigned char)(c + '\x1B' - '3');
    if (c == '2' || c == ' ')
        return 0;
    if (c == '8')
        return 0x7F;
    if (c == '/')
        return 0x1F;
    if (c >= 0x40 && c < 0x7F)
        return (unsigned char)(c & 0x1F);
    return c;
}
