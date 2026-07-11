/*
 * printing-smoke-main.c — Phase 9.4 headless check for macos/platform/printing.c.
 */

#include <stdio.h>
#include <stdlib.h>
#include <stdarg.h>
#include <string.h>
#include <unistd.h>

#include "putty.h"

void modalfatalbox(const char *fmt, ...)
{
    va_list ap;
    fputs("FATAL: ", stderr);
    va_start(ap, fmt);
    vfprintf(stderr, fmt, ap);
    va_end(ap);
    fputc('\n', stderr);
    exit(1);
}

void nonfatal(const char *fmt, ...)
{
    va_list ap;
    fputs("ERROR: ", stderr);
    va_start(ap, fmt);
    vfprintf(stderr, fmt, ap);
    va_end(ap);
    fputc('\n', stderr);
}

static char *make_temp_path(void)
{
    char template[] = "/tmp/putty-mac-print-smoke.XXXXXX";
    int fd = mkstemp(template);
    if (fd < 0)
        return NULL;
    close(fd);
    return dupstr(template);
}

int main(void)
{
    int nprinters = -1;
    printer_enum *pe;
    printer_job *pj;
    char *path;
    char *cmd;
    FILE *fp;
    char buf[64];
    size_t n;
    const char payload[] = "putty-mac-print-smoke\n";

    pe = printer_start_enum(&nprinters);
    if (nprinters != 0 || pe != NULL) {
        fprintf(stderr, "putty-mac-printing-smoke: enum should be empty\n");
        return 1;
    }
    printer_finish_enum(pe);
    if (printer_get_name(NULL, 0) != NULL) {
        fprintf(stderr, "putty-mac-printing-smoke: get_name should be NULL\n");
        return 1;
    }

    if (printer_start_job(NULL) != NULL || printer_start_job("") != NULL) {
        fprintf(stderr, "putty-mac-printing-smoke: empty printer should fail\n");
        return 1;
    }

    path = make_temp_path();
    if (!path) {
        fprintf(stderr, "putty-mac-printing-smoke: mkstemp failed\n");
        return 1;
    }
    cmd = dupprintf("cat >'%s'", path);

    pj = printer_start_job(cmd);
    sfree(cmd);
    if (!pj) {
        fprintf(stderr, "putty-mac-printing-smoke: start_job failed\n");
        unlink(path);
        sfree(path);
        return 1;
    }

    printer_job_data(pj, payload, sizeof(payload) - 1);
    printer_finish_job(pj);

    fp = fopen(path, "r");
    if (!fp) {
        fprintf(stderr, "putty-mac-printing-smoke: open output failed\n");
        unlink(path);
        sfree(path);
        return 1;
    }
    n = fread(buf, 1, sizeof(buf) - 1, fp);
    fclose(fp);
    unlink(path);
    sfree(path);
    buf[n] = '\0';

    if (strcmp(buf, payload) != 0) {
        fprintf(stderr, "putty-mac-printing-smoke: got \"%s\"\n", buf);
        return 1;
    }

    puts("putty-mac-printing-smoke: ok");
    return 0;
}
