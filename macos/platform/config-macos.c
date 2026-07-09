/*
 * config-macos.c — macOS-specific parts of the PuTTY configuration box.
 *
 * Mirrors unix/config-unix.c and the AppKit-relevant pieces of
 * unix/config-gtk.c. X11-only controls (window class, multi-font panel)
 * are intentionally omitted.
 */

#include <assert.h>
#include <stdlib.h>
#include <string.h>

#include "putty.h"
#include "dialog.h"
#include "storage.h"

static void about_handler(dlgcontrol *ctrl, dlgparam *dlg,
                          void *data, int event)
{
    (void)dlg;
    (void)data;
    if (event == EVENT_ACTION)
        about_box(ctrl->context.p);
}

void macos_setup_config_box(struct controlbox *b, bool midsession, int protocol)
{
    struct controlset *s;
    dlgcontrol *c;
    int i;

    (void)protocol;

    /*
     * The Conf structure contains two Unix-style elements which are
     * not configured here: stamp_utmp and login_shell. pterm does not
     * put up a configuration box at start, which is the only time
     * those would be useful.
     */

    /*
     * macOS has no printer drop-down list (same as Unix GTK).
     */
    s = ctrl_getset(b, "Terminal", "printing", "Remote-controlled printing");
    assert(s->ncontrols == 1 && s->ctrls[0]->type == CTRL_EDITBOX);
    s->ctrls[0]->editbox.has_list = false;

    /*
     * Local-command proxy is available on macOS.
     */
    if (!midsession) {
        s = ctrl_getset(b, "Connection/Proxy", "basics", NULL);
        for (i = 0; i < s->ncontrols; i++) {
            c = s->ctrls[i];
            if (c->type == CTRL_LISTBOX &&
                c->handler == proxy_type_handler) {
                c->context.i |= PROXY_UI_FLAG_LOCAL;
                break;
            }
        }
    }

    if (!midsession) {
        /*
         * About button on the standard action panel (alongside Open/Cancel).
         */
        s = ctrl_getset(b, "", "", "");
        c = ctrl_pushbutton(s, "About", 'a', HELPCTX(no_help),
                            about_handler, P(NULL));
        c->column = 0;
    }

    /*
     * Scrollbar on the left is natural on macOS.
     */
    s = ctrl_getset(b, "Window", "scrollback",
                    "Control the scrollback in the window");
    ctrl_checkbox(s, "Scrollbar on left", 'l',
                  HELPCTX(no_help),
                  conf_checkbox_handler,
                  I(CONF_scrollbar_on_left));
    for (i = 0; i < s->ncontrols; i++) {
        c = s->ctrls[i];
        if (c->type == CTRL_CHECKBOX &&
            c->context.i == CONF_scrollbar) {
            if (i < s->ncontrols - 2) {
                c = s->ctrls[s->ncontrols - 1];
                memmove(s->ctrls + i + 2, s->ctrls + i + 1,
                        (s->ncontrols - i - 2) * sizeof(dlgcontrol *));
                s->ctrls[i + 1] = c;
            }
            break;
        }
    }

    /*
     * Honour UTF-8 locale override (same rationale as GTK).
     */
    s = ctrl_getset(b, "Window/Translation", "trans",
                    "Character set translation on received data");
    ctrl_checkbox(s, "Override with UTF-8 if locale says so", 'l',
                  HELPCTX(translation_utf8_override),
                  conf_checkbox_handler,
                  I(CONF_utf8_override));

#ifdef OSX_META_KEY_CONFIG
    /*
     * Option and/or Command may act as Meta, or keep their OS roles.
     */
    s = ctrl_getset(b, "Terminal/Keyboard", "meta",
                    "Choose the Meta key:");
    ctrl_checkbox(s, "Option key acts as Meta", 'p',
                  HELPCTX(no_help),
                  conf_checkbox_handler, I(CONF_osx_option_meta));
    ctrl_checkbox(s, "Command key acts as Meta", 'm',
                  HELPCTX(no_help),
                  conf_checkbox_handler, I(CONF_osx_command_meta));
#endif
}
