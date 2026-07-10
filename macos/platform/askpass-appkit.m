/*
 * askpass-appkit.m — AppKit passphrase prompt for macOS pageant (Phase 7.4).
 *
 * Implements gtk_askpass_main() so CLI pageant and `pageant --askpass`
 * (SSH_ASKPASS) can prompt without GTK or an X11 DISPLAY.
 */

#import <AppKit/AppKit.h>
#import <Foundation/Foundation.h>

#include "putty.h"

const bool buildinfo_gtk_relevant = false;

void random_add_noise(NoiseSourceId source, const void *noise, int length)
{
    (void)source;
    (void)noise;
    (void)length;
}

static void mac_askpass_ensure_app(void)
{
    if (!NSApp) {
        [NSApplication sharedApplication];
        [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
    }
}

char *gtk_askpass_main(const char *display, const char *wintitle,
                       const char *prompt, bool *success)
{
    NSAlert *alert;
    NSSecureTextField *field;
    NSModalResponse response;
    NSString *title;
    NSString *message;
    const char *utf8;
    char *result;

    (void)display;

    if (success)
        *success = false;

    /*
     * Non-interactive smoke / CI: PUTTY_ASKPASS_RESPONSE sets the
     * returned passphrase (empty string allowed).
     */
    {
        const char *auto_resp = getenv("PUTTY_ASKPASS_RESPONSE");
        if (auto_resp) {
            if (success)
                *success = true;
            return dupstr(auto_resp);
        }
    }

    @autoreleasepool {
        mac_askpass_ensure_app();
        [NSApp activateIgnoringOtherApps:YES];

        title = wintitle
            ? [NSString stringWithUTF8String:wintitle]
            : @"Pageant passphrase prompt";
        message = prompt
            ? [NSString stringWithUTF8String:prompt]
            : @"Enter passphrase:";
        if (!title)
            title = @"Pageant passphrase prompt";
        if (!message)
            message = @"Enter passphrase:";

        alert = [[NSAlert alloc] init];
        alert.messageText = title;
        alert.informativeText = message;
        alert.alertStyle = NSAlertStyleInformational;
        [alert addButtonWithTitle:@"OK"];
        [alert addButtonWithTitle:@"Cancel"];

        field = [[NSSecureTextField alloc]
            initWithFrame:NSMakeRect(0, 0, 280, 24)];
        field.accessibilityLabel = message;
        alert.accessoryView = field;
        alert.window.initialFirstResponder = field;
        alert.window.autorecalculatesKeyViewLoop = YES;
        [alert.window recalculateKeyViewLoop];

        response = [alert runModal];
        if (response != NSAlertFirstButtonReturn) {
            if (success)
                *success = false;
            return dupstr("passphrase prompt cancelled");
        }

        utf8 = [[field stringValue] UTF8String];
        result = dupstr(utf8 ? utf8 : "");
        if (success)
            *success = true;
        return result;
    }
}
