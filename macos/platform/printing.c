/*
 * Printing interface for PuTTY on macOS.
 *
 * Remote-controlled ANSI printer output (Phase 9.4) mirrors unix/printing.c:
 * CONF_printer is a shell command (typically "lpr") that receives the job
 * on stdin. Session transcript printing uses NSPrintOperation in Swift.
 */

#include <assert.h>
#include <stdio.h>

#include "putty.h"

struct printer_job_tag {
    FILE *fp;
    bool write_failed;
};

printer_job *printer_start_job(char *printer)
{
    printer_job *pj;

    if (!printer || !printer[0])
        return NULL;

    pj = snew(printer_job);
    /*
     * WORKAROUND: Treat the printer string as a command to pipe to —
     * typically lpr under CUPS, matching the Unix GTK frontend. No native
     * CUPS job API; popen is the supported parity path (PARITY.md).
     * — see .cursor/rules/agents.mdc
     */
    pj->fp = popen(printer, "w");
    if (!pj->fp) {
        sfree(pj);
        return NULL;
    }
    pj->write_failed = false;
    return pj;
}

void printer_job_data(printer_job *pj, const void *data, size_t len)
{
    if (!pj)
        return;

    if (fwrite(data, 1, len, pj->fp) < len)
        pj->write_failed = true;
}

void printer_finish_job(printer_job *pj)
{
    int status;

    if (!pj)
        return;

    status = pclose(pj->fp);
    if (pj->write_failed || status != 0)
        nonfatal("Printer job failed (short write or command exit status %d)",
                 status);
    sfree(pj);
}

/*
 * No printer enumeration drop-down on macOS (same as Unix GTK). Config
 * uses a free-text edit box for the print command.
 */
printer_enum *printer_start_enum(int *nprinters_ptr)
{
    *nprinters_ptr = 0;
    return NULL;
}

char *printer_get_name(printer_enum *pe, int i)
{
    (void)pe;
    (void)i;
    return NULL;
}

void printer_finish_enum(printer_enum *pe)
{
    (void)pe;
}
