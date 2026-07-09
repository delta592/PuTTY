/*
 * config-macos.c — macOS-specific parts of the PuTTY configuration box.
 *
 * Mirrors unix/config-unix.c and the AppKit-relevant pieces of
 * unix/config-gtk.c. X11-only controls (window class, multi-font panel)
 * are intentionally omitted. Phase 6.2 adds Restore Defaults / Duplicate.
 */

#include <assert.h>
#include <stdlib.h>
#include <string.h>

#include "putty.h"
#include "dialog.h"
#include "storage.h"

#include "config-appkit.h"

static void about_handler(dlgcontrol *ctrl, dlgparam *dlg,
                          void *data, int event)
{
    (void)dlg;
    (void)data;
    if (event == EVENT_ACTION)
        about_box(ctrl->context.p);
}

static void restore_defaults_handler(dlgcontrol *ctrl, dlgparam *dlg,
                                     void *data, int event)
{
    Conf *conf = (Conf *)data;

    (void)ctrl;
    if (event != EVENT_ACTION)
        return;

    do_defaults(NULL, conf);
    dlg_refresh(NULL, dlg);
}

static dlgcontrol *mac_find_saved_sessions_ctrl(
    struct controlbox *b, int type)
{
    size_t i, j;

    if (!b)
        return NULL;
    for (i = 0; i < b->nctrlsets; i++) {
        struct controlset *s = b->ctrlsets[i];
        if (!s->pathname || strcmp(s->pathname, "Session") != 0)
            continue;
        if (!s->boxname || strcmp(s->boxname, "savedsessions") != 0)
            continue;
        for (j = 0; j < s->ncontrols; j++) {
            dlgcontrol *c = s->ctrls[j];
            if (c->type != type)
                continue;
            if (type == CTRL_EDITBOX &&
                c->label && !strcmp(c->label, "Saved Sessions"))
                return c;
            if (type == CTRL_LISTBOX)
                return c;
        }
    }
    return NULL;
}

/*
 * Duplicate the current Conf under a new saved-session name derived from
 * the Saved Sessions edit box (or the selected list entry).
 */
static void duplicate_session_handler(dlgcontrol *ctrl, dlgparam *dlg,
                                      void *data, int event)
{
    Conf *conf = (Conf *)data;
    struct controlbox *box;
    dlgcontrol *edit, *list;
    char *base = NULL, *newname = NULL, *errmsg;
    struct sesslist sesslist;
    int i;

    (void)ctrl;
    if (event != EVENT_ACTION)
        return;

    box = mac_config_dlg_ctrlbox(dlg);
    if (!box) {
        dlg_beep(dlg);
        return;
    }

    edit = mac_find_saved_sessions_ctrl(box, CTRL_EDITBOX);
    list = mac_find_saved_sessions_ctrl(box, CTRL_LISTBOX);
    if (!edit || !list) {
        dlg_beep(dlg);
        return;
    }

    base = dlg_editbox_get(edit, dlg);
    if (!base || !base[0]) {
        sfree(base);
        i = dlg_listbox_index(list, dlg);
        if (i < 0) {
            dlg_beep(dlg);
            return;
        }
        get_sesslist(&sesslist, true);
        if (i >= sesslist.nsessions) {
            get_sesslist(&sesslist, false);
            dlg_beep(dlg);
            return;
        }
        base = dupstr(sesslist.sessions[i]);
        get_sesslist(&sesslist, false);
    }

    newname = dupcat(base, " Copy");
    sfree(base);

    errmsg = save_settings(newname, conf);
    if (errmsg) {
        dlg_error_msg(dlg, errmsg);
        sfree(errmsg);
        sfree(newname);
        return;
    }

    dlg_editbox_set(edit, dlg, newname);
    sfree(newname);

    get_sesslist(&sesslist, true);
    dlg_listbox_clear(list, dlg);
    for (i = 0; i < sesslist.nsessions; i++)
        dlg_listbox_add(list, dlg, sesslist.sessions[i]);
    get_sesslist(&sesslist, false);
    dlg_refresh(NULL, dlg);
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

    /*
     * Action panel: About (pre-session), Restore Defaults, Duplicate.
     * Columns 3/4 are Open|Apply and Cancel from portable setup_config_box.
     */
    s = ctrl_getset(b, "", "", "");
    if (!midsession) {
        c = ctrl_pushbutton(s, "About", 'a', HELPCTX(no_help),
                            about_handler, P(NULL));
        c->column = 0;
    }
    c = ctrl_pushbutton(s, "Restore Defaults", NO_SHORTCUT, HELPCTX(no_help),
                        restore_defaults_handler, P(NULL));
    c->column = 1;
    if (!midsession) {
        c = ctrl_pushbutton(s, "Duplicate", NO_SHORTCUT, HELPCTX(no_help),
                            duplicate_session_handler, P(NULL));
        c->column = 2;
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
