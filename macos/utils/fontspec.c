/*
 * macos/utils/fontspec.c: FontSpec for macOS (AppKit / Core Text).
 *
 * Font names use the form mac:PostScriptName:pointSize, e.g.
 * mac:SFMono-Regular:12. TerminalView / TerminalFontCache parse this when
 * creating NSFont instances; settings store the string opaquely.
 */

#include "putty.h"
#include "platform.h"

FontSpec *fontspec_new(const char *name)
{
    FontSpec *f = snew(FontSpec);
    f->name = dupstr(name);
    return f;
}

FontSpec *fontspec_new_default(void)
{
    return fontspec_new(DEFAULT_MAC_FONT);
}

FontSpec *fontspec_copy(const FontSpec *f)
{
    return fontspec_new(f->name);
}

void fontspec_free(FontSpec *f)
{
    sfree(f->name);
    sfree(f);
}

void fontspec_serialise(BinarySink *bs, FontSpec *f)
{
    put_asciz(bs, f->name);
}

FontSpec *fontspec_deserialise(BinarySource *src)
{
    return fontspec_new(get_asciz(src));
}
