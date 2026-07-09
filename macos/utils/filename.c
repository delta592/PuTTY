/*
 * macos/utils/filename.c: Filename and f_open() for UTF-8 macOS paths.
 *
 * Paths are stored as UTF-8 in NFC. f_open() sets close-on-exec on all
 * descriptors and uses restrictive create flags for private files.
 */

#include <assert.h>
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>

#include "putty.h"
#include "misc.h"

static char *macos_filename_path_from_utf8(const char *str)
{
    BinarySource src[1];

    if (!str)
        return dupstr("");

    BinarySource_BARE_INIT(src, str, strlen(str));
    while (get_avail(src)) {
        DecodeUTF8Failure err;
        decode_utf8(src, &err);
        if (err != DUTF8_SUCCESS)
            return dupstr(str);        /* preserve non-UTF-8 paths as-is */
    }

    strbuf *nfc = utf8_to_nfc(ptrlen_from_asciz(str));
    char *ret = strbuf_to_str(nfc);
    strbuf_free(nfc);
    return ret;
}

Filename *filename_from_str(const char *str)
{
    Filename *fn = snew(Filename);
    fn->path = macos_filename_path_from_utf8(str);
    return fn;
}

Filename *filename_copy(const Filename *fn)
{
    return filename_from_str(fn->path);
}

const char *filename_to_str(const Filename *fn)
{
    return fn->path;
}

bool filename_equal(const Filename *f1, const Filename *f2)
{
    return !strcmp(f1->path, f2->path);
}

bool filename_is_null(const Filename *fn)
{
    return !fn->path[0];
}

void filename_free(Filename *fn)
{
    sfree(fn->path);
    sfree(fn);
}

void filename_serialise(BinarySink *bs, const Filename *f)
{
    put_asciz(bs, f->path);
}

Filename *filename_deserialise(BinarySource *src)
{
    return filename_from_str(get_asciz(src));
}

char filename_char_sanitise(char c)
{
    if (c == '/')
        return '.';
    return c;
}

static FILE *f_open_fd(int fd, char const *mode)
{
    FILE *fp;

    if (fd < 0)
        return NULL;

    cloexec(fd);
    fp = fdopen(fd, mode);
    if (!fp)
        close(fd);
    return fp;
}

FILE *f_open(const Filename *filename, char const *mode, bool is_private)
{
    if (!is_private) {
        FILE *fp = fopen(filename->path, mode);
        if (fp)
            cloexec(fileno(fp));
        return fp;
    }

    assert(mode[0] == 'w');            /* private mode is for new secret files */

    {
        int fd = open(filename->path,
                      O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC | O_NOFOLLOW,
                      0600);
        return f_open_fd(fd, mode);
    }
}
