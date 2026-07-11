/*
 * macos/platform/seat-dialogs.mm — AppKit security prompts for MacGuiSeat (Phase 5.3).
 */

#import <AppKit/AppKit.h>

#include <stdlib.h>
#include <string.h>

#include "seat-dialogs.h"

#include "putty.h"
#include "storage.h"

static void *mac_gui_parent_window;

@interface MacAlertHelpDelegate : NSObject <NSAlertDelegate>
@property (nonatomic) HelpCtx helpctx;
@end

@implementation MacAlertHelpDelegate
- (BOOL)alertShowHelp:(NSAlert *)alert
{
    (void)alert;
    /* Phase 9.5: Swift PuttyHelp observes this and opens the WebKit help window. */
    [[NSNotificationCenter defaultCenter]
        postNotificationName:@"PuTTYOpenBundledHelp" object:nil];
    return YES;
}
@end

void mac_gui_dialogs_set_parent_window(void *nswindow)
{
    mac_gui_parent_window = nswindow;
}

void *mac_gui_dialogs_get_parent_window(void)
{
    return mac_gui_parent_window;
}

void mac_gui_dialogs_ensure_app(void)
{
    if (!NSApp) {
        [NSApplication sharedApplication];
        [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
    }
}

static bool mac_gui_dialogs_auto_accept(void)
{
    const char *v = getenv("PUTTY_MACOS_DIALOG_AUTO_ACCEPT");
    return v && v[0] == '1' && v[1] == '\0';
}

static bool mac_gui_dialogs_auto_reject(void)
{
    const char *v = getenv("PUTTY_MACOS_DIALOG_AUTO_REJECT");
    return v && v[0] == '1' && v[1] == '\0';
}

static NSWindow *mac_gui_parent_nswindow(void)
{
    if (mac_gui_parent_window)
        return (__bridge NSWindow *)mac_gui_parent_window;
    return [NSApp keyWindow] ?: [NSApp mainWindow];
}

static NSString *mac_nsstring_from_utf8(const char *utf8)
{
    if (!utf8)
        return @"";
    NSString *s = [NSString stringWithUTF8String:utf8];
    return s ?: @"";
}

static char *mac_dup_nsstring_utf8(NSString *s)
{
    if (!s)
        return dupstr("");
    const char *utf8 = [s UTF8String];
    return dupstr(utf8 ? utf8 : "");
}

typedef struct MacFormatSeatDialogText {
    char *title;
    char *message;
    char *more_info;
} MacFormatSeatDialogText;

static MacFormatSeatDialogText mac_format_seatdialogtext(SeatDialogText *text)
{
    MacFormatSeatDialogText out;
    strbuf *msg = strbuf_new();
    strbuf *more = strbuf_new();

    memset(&out, 0, sizeof(out));

    if (!text) {
        out.message = strbuf_to_str(msg);
        out.more_info = strbuf_to_str(more);
        return out;
    }

    for (size_t i = 0; i < text->nitems; i++) {
        SeatDialogTextItem *item = &text->items[i];
        switch (item->type) {
          case SDT_PARA:
          case SDT_DISPLAY:
          case SDT_SCARY_HEADING:
            put_fmt(msg, "%s\n\n", item->text);
            break;
          case SDT_TITLE:
            out.title = dupstr(item->text);
            break;
          case SDT_MORE_INFO_KEY:
            put_fmt(more, "%s", item->text);
            break;
          case SDT_MORE_INFO_VALUE_SHORT:
            put_fmt(more, ": %s\n", item->text);
            break;
          case SDT_MORE_INFO_VALUE_BLOB: {
            const char *p = item->text;
            size_t len = p ? strlen(p) : 0;
            put_byte(more, ':');
            for (size_t off = 0; off < len; ) {
                size_t linelen = len - off;
                if (linelen > 72)
                    linelen = 72;
                put_byte(more, '\n');
                put_data(more, p + off, linelen);
                off += linelen;
            }
            put_byte(more, '\n');
            break;
          }
          default:
            break;
        }
    }

    while (strbuf_chomp(msg, '\n')) {}
    while (strbuf_chomp(more, '\n')) {}

    out.message = strbuf_to_str(msg);
    out.more_info = strbuf_to_str(more);
    return out;
}

static void mac_free_formatted_dialog_text(MacFormatSeatDialogText *fmt)
{
    if (!fmt)
        return;
    sfree(fmt->title);
    sfree(fmt->message);
    sfree(fmt->more_info);
    memset(fmt, 0, sizeof(*fmt));
}

static void mac_prepare_alert_help(NSAlert *alert, HelpCtx helpctx)
{
    static MacAlertHelpDelegate *delegate;
    if (!delegate)
        delegate = [MacAlertHelpDelegate new];
    delegate.helpctx = helpctx;
    alert.delegate = delegate;
    alert.showsHelp = YES;
}

static void mac_alert_run(
    NSAlert *alert, NSWindow *parent,
    void (^completion)(NSModalResponse response))
{
    mac_gui_dialogs_ensure_app();

    if (parent) {
        [alert beginSheetModalForWindow:parent completionHandler:completion];
    } else {
        dispatch_async(dispatch_get_main_queue(), ^{
            completion([alert runModal]);
        });
    }
}

const SeatDialogPromptDescriptions *mac_seat_prompt_descriptions(Seat *seat)
{
    static const SeatDialogPromptDescriptions descs = {
        .hk_accept_action = "click Accept",
        .hk_connect_once_action = "click Connect Once",
        .hk_cancel_action = "click Cancel",
        .hk_cancel_action_Participle = "Clicking Cancel",
        .weak_accept_action = "click Continue",
        .weak_cancel_action = "click Cancel",
    };
    (void)seat;
    return &descs;
}

struct mac_hostkey_dialog_ctx {
    Seat *seat;
    char *host;
    int port;
    char *keytype;
    char *keystr;
    void (*callback)(void *ctx, SeatPromptResult result);
    void *callback_ctx;
};

static void mac_drain_toplevel_callbacks(void)
{
    /*
     * Dialog completion handlers run outside mac_uxsel_fire. SSH may
     * queue ic_out_pq / ic_process_queue from the seat callback; drain
     * them immediately so NEWKEYS / USERAUTH are not left sitting.
     */
    while (run_toplevel_callbacks())
        ;
}

static void mac_hostkey_dialog_finish(
    struct mac_hostkey_dialog_ctx *ctx, SeatPromptResult result, bool store)
{
    if (store && ctx->seat)
        store_host_key(ctx->seat, ctx->host, ctx->port, ctx->keytype, ctx->keystr);
    if (ctx->callback)
        ctx->callback(ctx->callback_ctx, result);
    sfree(ctx->host);
    sfree(ctx->keytype);
    sfree(ctx->keystr);
    sfree(ctx);
    mac_drain_toplevel_callbacks();
}

SeatPromptResult mac_seat_confirm_ssh_host_key(
    Seat *seat, const char *host, int port, const char *keytype,
    char *keystr, SeatDialogText *text, HelpCtx helpctx,
    void (*callback)(void *ctx, SeatPromptResult result), void *ctx)
{
    MacFormatSeatDialogText fmt = mac_format_seatdialogtext(text);
    struct mac_hostkey_dialog_ctx *dctx;
    NSString *title, *message;
    NSAlert *alert;
    NSWindow *parent;

    if (mac_gui_dialogs_auto_reject()) {
        mac_free_formatted_dialog_text(&fmt);
        if (callback) {
            callback(ctx, SPR_USER_ABORT);
            return SPR_INCOMPLETE;
        }
        return SPR_USER_ABORT;
    }

    if (mac_gui_dialogs_auto_accept()) {
        mac_free_formatted_dialog_text(&fmt);
        if (callback) {
            store_host_key(seat, host, port, keytype, keystr);
            callback(ctx, SPR_OK);
            return SPR_INCOMPLETE;
        }
        store_host_key(seat, host, port, keytype, keystr);
        return SPR_OK;
    }

    dctx = snew(struct mac_hostkey_dialog_ctx);
    dctx->seat = seat;
    dctx->host = dupstr(host);
    dctx->port = port;
    dctx->keytype = dupstr(keytype);
    dctx->keystr = dupstr(keystr);
    dctx->callback = callback;
    dctx->callback_ctx = ctx;

    title = mac_nsstring_from_utf8(fmt.title ? fmt.title : "Unknown host key");
    message = mac_nsstring_from_utf8(fmt.message);
    if (fmt.more_info && *fmt.more_info) {
        message = [message stringByAppendingFormat:
            @"\n\n%@", mac_nsstring_from_utf8(fmt.more_info)];
    }
    mac_free_formatted_dialog_text(&fmt);

    alert = [[NSAlert alloc] init];
    alert.alertStyle = NSAlertStyleWarning;
    alert.messageText = title;
    alert.informativeText = message;
    [alert addButtonWithTitle:@"Accept"];
    [alert addButtonWithTitle:@"Connect Once"];
    [alert addButtonWithTitle:@"Cancel"];
    mac_prepare_alert_help(alert, helpctx);

    parent = mac_gui_parent_nswindow();

    if (!callback) {
        NSModalResponse response = [alert runModal];
        if (response == NSAlertFirstButtonReturn) {
            store_host_key(seat, host, port, keytype, keystr);
            sfree(dctx);
            return SPR_OK;
        }
        if (response == NSAlertSecondButtonReturn) {
            sfree(dctx);
            return SPR_OK;
        }
        sfree(dctx);
        return SPR_USER_ABORT;
    }

    mac_alert_run(alert, parent, ^(NSModalResponse response) {
        if (response == NSAlertFirstButtonReturn)
            mac_hostkey_dialog_finish(dctx, SPR_OK, true);
        else if (response == NSAlertSecondButtonReturn)
            mac_hostkey_dialog_finish(dctx, SPR_OK, false);
        else
            mac_hostkey_dialog_finish(dctx, SPR_USER_ABORT, false);
    });

    return SPR_INCOMPLETE;
}

struct mac_simple_prompt_ctx {
    void (*callback)(void *ctx, SeatPromptResult result);
    void *callback_ctx;
};

static void mac_simple_prompt_finish(
    struct mac_simple_prompt_ctx *sctx, SeatPromptResult result)
{
    if (sctx->callback)
        sctx->callback(sctx->callback_ctx, result);
    sfree(sctx);
    mac_drain_toplevel_callbacks();
}

static SeatPromptResult mac_seat_confirm_weak_dialog(
    Seat *seat, SeatDialogText *text, HelpCtx helpctx,
    void (*callback)(void *ctx, SeatPromptResult result), void *ctx)
{
    MacFormatSeatDialogText fmt = mac_format_seatdialogtext(text);
    struct mac_simple_prompt_ctx *sctx;
    NSString *title, *message;
    NSAlert *alert;
    NSWindow *parent;

    (void)seat;

    if (mac_gui_dialogs_auto_reject()) {
        mac_free_formatted_dialog_text(&fmt);
        if (callback) {
            callback(ctx, SPR_USER_ABORT);
            return SPR_INCOMPLETE;
        }
        return SPR_USER_ABORT;
    }

    if (mac_gui_dialogs_auto_accept()) {
        mac_free_formatted_dialog_text(&fmt);
        if (callback) {
            callback(ctx, SPR_OK);
            return SPR_INCOMPLETE;
        }
        return SPR_OK;
    }

    sctx = snew(struct mac_simple_prompt_ctx);
    sctx->callback = callback;
    sctx->callback_ctx = ctx;

    title = mac_nsstring_from_utf8(fmt.title ? fmt.title : "Security warning");
    message = mac_nsstring_from_utf8(fmt.message);
    mac_free_formatted_dialog_text(&fmt);

    alert = [[NSAlert alloc] init];
    alert.alertStyle = NSAlertStyleWarning;
    alert.messageText = title;
    alert.informativeText = message;
    [alert addButtonWithTitle:@"Continue"];
    [alert addButtonWithTitle:@"Cancel"];
    mac_prepare_alert_help(alert, helpctx);

    parent = mac_gui_parent_nswindow();

    if (!callback) {
        NSModalResponse response = [alert runModal];
        sfree(sctx);
        return (response == NSAlertFirstButtonReturn) ? SPR_OK : SPR_USER_ABORT;
    }

    mac_alert_run(alert, parent, ^(NSModalResponse response) {
        if (response == NSAlertFirstButtonReturn)
            mac_simple_prompt_finish(sctx, SPR_OK);
        else
            mac_simple_prompt_finish(sctx, SPR_USER_ABORT);
    });

    return SPR_INCOMPLETE;
}

SeatPromptResult mac_seat_confirm_weak_crypto_primitive(
    Seat *seat, SeatDialogText *text,
    void (*callback)(void *ctx, SeatPromptResult result), void *ctx)
{
    return mac_seat_confirm_weak_dialog(
        seat, text, NULL_HELPCTX, callback, ctx);
}

SeatPromptResult mac_seat_confirm_weak_cached_hostkey(
    Seat *seat, SeatDialogText *text,
    void (*callback)(void *ctx, SeatPromptResult result), void *ctx)
{
    return mac_seat_confirm_weak_dialog(
        seat, text, NULL_HELPCTX, callback, ctx);
}

static void mac_userpass_fill_auto(prompts_t *p)
{
    const char *user = getenv("PUTTY_MACOS_DIALOG_AUTO_USER");
    const char *pass = getenv("PUTTY_MACOS_DIALOG_AUTO_PASS");

    for (size_t i = 0; i < p->n_prompts; i++) {
        prompt_t *pr = p->prompts[i];
        const char *value = "";

        if (pr->echo) {
            if (user && *user)
                value = user;
        } else {
            if (pass && *pass)
                value = pass;
            else if (user && *user)
                value = user;
        }
        prompt_set_result(pr, value);
    }
}

SeatPromptResult mac_seat_get_userpass_input_dialog(prompts_t *p)
{
    NSView *content;
    NSMutableArray<NSTextField *> *fields = [NSMutableArray array];
    CGFloat y;
    CGFloat width = 420;
    CGFloat fieldHeight = 22;
    CGFloat labelGap = 6;
    CGFloat rowGap = 10;
    NSString *title;
    CGFloat contentHeight;
    NSModalResponse response;
    SeatPromptResult spr;

    if (!p)
        return SPR_SW_ABORT("No prompts");

    if (mac_gui_dialogs_auto_reject()) {
        for (size_t i = 0; i < p->n_prompts; i++)
            prompt_set_result(p->prompts[i], "");
        return SPR_USER_ABORT;
    }

    if (mac_gui_dialogs_auto_accept()) {
        mac_userpass_fill_auto(p);
        return SPR_OK;
    }

    mac_gui_dialogs_ensure_app();

    title = mac_nsstring_from_utf8(
        (p->name && (!p->name_reqd || *p->name)) ? p->name : "PuTTY");

    contentHeight = 8;
    if (p->instruction && *p->instruction)
        contentHeight += 44;
    contentHeight += (CGFloat)p->n_prompts * (16 + labelGap + fieldHeight + rowGap);

    content = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, width, contentHeight)];
    y = contentHeight - 8;

    if (p->instruction && *p->instruction) {
        NSTextField *label = [NSTextField labelWithString:
            mac_nsstring_from_utf8(p->instruction)];
        [label setFrame:NSMakeRect(12, y - 36, width - 24, 36)];
        label.lineBreakMode = NSLineBreakByWordWrapping;
        label.maximumNumberOfLines = 0;
        [content addSubview:label];
        y -= 44;
    }

    for (size_t i = 0; i < p->n_prompts; i++) {
        prompt_t *pr = p->prompts[i];
        NSTextField *caption = [NSTextField labelWithString:
            mac_nsstring_from_utf8(pr->prompt)];
        [caption setFrame:NSMakeRect(12, y - 16, width - 24, 16)];
        caption.refusesFirstResponder = YES;
        [content addSubview:caption];
        y -= 16 + labelGap;

        NSTextField *field;
        if (pr->echo)
            field = [[NSTextField alloc] initWithFrame:
                NSMakeRect(12, y - fieldHeight, width - 24, fieldHeight)];
        else
            field = [[NSSecureTextField alloc] initWithFrame:
                NSMakeRect(12, y - fieldHeight, width - 24, fieldHeight)];

        field.stringValue = @"";
        field.accessibilityLabel = caption.stringValue;
        [field setAccessibilityTitleUIElement:caption];
        [content addSubview:field];
        [fields addObject:field];
        y -= fieldHeight + rowGap;
    }

    NSAlert *alert = [[NSAlert alloc] init];
    alert.messageText = title;
    alert.informativeText = @"";
    alert.accessoryView = content;
    [alert addButtonWithTitle:@"OK"];
    [alert addButtonWithTitle:@"Cancel"];

    if (fields.count > 0) {
        alert.window.initialFirstResponder = fields[0];
        alert.window.autorecalculatesKeyViewLoop = YES;
        [alert.window recalculateKeyViewLoop];
    }

    response = [alert runModal];

    if (response != NSAlertFirstButtonReturn) {
        for (size_t i = 0; i < p->n_prompts; i++)
            prompt_set_result(p->prompts[i], "");
        spr = SPR_USER_ABORT;
    } else {
        for (size_t i = 0; i < p->n_prompts; i++) {
            char *value = mac_dup_nsstring_utf8(fields[i].stringValue);
            prompt_set_result(p->prompts[i], value);
            sfree(value);
        }
        spr = SPR_OK;
    }

    return spr;
}

static void mac_show_error_alert(const char *title, const char *msg, HelpCtx helpctx)
{
    NSAlert *alert;

    if (mac_gui_dialogs_auto_accept() || mac_gui_dialogs_auto_reject())
        return;

    mac_gui_dialogs_ensure_app();

    alert = [[NSAlert alloc] init];
    alert.alertStyle = NSAlertStyleCritical;
    alert.messageText = mac_nsstring_from_utf8(title);
    alert.informativeText = mac_nsstring_from_utf8(msg);
    [alert addButtonWithTitle:@"OK"];
    mac_prepare_alert_help(alert, helpctx);

    NSWindow *parent = mac_gui_parent_nswindow();
    if (parent)
        [alert beginSheetModalForWindow:parent completionHandler:nil];
    else
        [alert runModal];
}

void mac_seat_show_connection_fatal(
    const char *title, const char *msg, HelpCtx helpctx)
{
    mac_show_error_alert(title, msg, helpctx);
}

void mac_seat_show_nonfatal(const char *title, const char *msg, HelpCtx helpctx)
{
    mac_show_error_alert(title, msg, helpctx);
}

struct mac_dialog_smoke_cb_state {
    bool called;
    SeatPromptResult result;
};

static void mac_dialog_smoke_cb(void *ctx, SeatPromptResult result)
{
    struct mac_dialog_smoke_cb_state *state =
        (struct mac_dialog_smoke_cb_state *)ctx;

    state->called = true;
    state->result = result;
}

int mac_gui_seat_dialogs_smoke(void)
{
    const SeatDialogPromptDescriptions *descs;
    SeatPromptResult spr;
    struct mac_dialog_smoke_cb_state cb_state;

    descs = mac_seat_prompt_descriptions(NULL);
    if (!descs)
        return 1;
    if (strcmp(descs->hk_accept_action, "click Accept") != 0)
        return 2;
    if (strcmp(descs->weak_accept_action, "click Continue") != 0)
        return 3;

    memset(&cb_state, 0, sizeof(cb_state));
    cb_state.result = SPR_USER_ABORT;
    setenv("PUTTY_MACOS_DIALOG_AUTO_ACCEPT", "1", 1);
    spr = mac_seat_confirm_ssh_host_key(
        NULL, "example.com", 22, "ssh-ed25519", "AAAAB3Nza",
        NULL, NULL_HELPCTX, mac_dialog_smoke_cb, &cb_state);
    unsetenv("PUTTY_MACOS_DIALOG_AUTO_ACCEPT");

    if (spr.kind != SPRK_INCOMPLETE || !cb_state.called ||
        cb_state.result.kind != SPRK_OK)
        return 4;

    memset(&cb_state, 0, sizeof(cb_state));
    cb_state.result = SPR_OK;
    setenv("PUTTY_MACOS_DIALOG_AUTO_REJECT", "1", 1);
    spr = mac_seat_confirm_weak_crypto_primitive(
        NULL, NULL, mac_dialog_smoke_cb, &cb_state);
    unsetenv("PUTTY_MACOS_DIALOG_AUTO_REJECT");

    if (spr.kind != SPRK_INCOMPLETE || !cb_state.called ||
        cb_state.result.kind != SPRK_USER_ABORT)
        return 5;

    {
        prompts_t *p = new_prompts();
        add_prompt(p, dupstr("Password:"), false);
        setenv("PUTTY_MACOS_DIALOG_AUTO_PASS", "secret", 1);
        setenv("PUTTY_MACOS_DIALOG_AUTO_ACCEPT", "1", 1);
        spr = mac_seat_get_userpass_input_dialog(p);
        unsetenv("PUTTY_MACOS_DIALOG_AUTO_PASS");
        unsetenv("PUTTY_MACOS_DIALOG_AUTO_ACCEPT");
        if (spr.kind != SPRK_OK)
            return 6;
        if (strcmp(prompt_get_result_ref(p->prompts[0]), "secret") != 0)
            return 7;
        free_prompts(p);
    }

    return 0;
}
