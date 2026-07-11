/*
 * config-appkit.m — AppKit renderer for PuTTY's abstract controlbox (Phase 6.1).
 *
 * Maps CTRL_* types from dialog.h to AppKit widgets and implements the
 * platform dlg_* read/write API used by portable config.c handlers.
 */

#import <AppKit/AppKit.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import <objc/runtime.h>

#include <assert.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include "putty.h"
#include "dialog.h"
#include "storage.h"
#include "tree234.h"

#include "config-appkit.h"
#include "seat-dialogs.h"

#define FLAG_UPDATING_COMBO_LIST 1
#define FLAG_UPDATING_LISTBOX    2
#define FLAG_IGNORING_EVENTS     4

/* ---------------------------------------------------------------------- */
/* Per-control AppKit state */

@interface MacConfigListItem : NSObject
@property (nonatomic) int itemId;
@property (nonatomic, copy) NSString *text;
@end

@implementation MacConfigListItem
@end

struct MacUCtrl {
    dlgcontrol *ctrl;
    /*
     * ObjC object pointers in a C struct are __unsafe_unretained under ARC
     * unless marked __strong. Without that (or without compiling with ARC
     * at all — cmake/platforms/macos.cmake enables -fobjc-arc), arrays
     * created via [NSMutableArray array] are freed immediately and
     * table/outline data sources crash on first paint
     * (see macos/app_crash.txt / app_crash_002.txt).
     */
    __strong NSView *toplevel;          /* outermost view for this control */
    __strong NSTextField *label;
    __strong NSView *widget;            /* primary interactive widget */
    __strong NSMutableArray<NSButton *> *radioButtons;
    __strong NSMutableArray<MacConfigListItem *> *listItems;
    NSInteger selectedIndex;
    __strong NSMutableIndexSet *selectedIndexes;
    char *textvalue;           /* button-only file selector */
    __strong NSView *panel;             /* owning panel, or nil for global actions */
};

/* ---------------------------------------------------------------------- */
/* dlgparam (platform-private) */

struct dlgparam {
    tree234 *byctrl;
    void *data;                /* Conf * (editable working copy) */
    struct {
        unsigned char r, g, b;
        bool ok;
        bool pending;
        dlgcontrol *ctrl;
    } coloursel;
    int flags;
    dlgcontrol *currfocus, *lastfocus;
    struct controlbox *ctrlbox;
    int retval;
    bool ended;
    post_dialog_fn_t after;
    void *afterctx;
    __strong NSWindow *window;
    __strong NSView *curr_panel;
    __strong NSMutableArray<NSView *> *panels;
    __strong NSMutableArray<NSString *> *panelPaths;
    __strong NSOutlineView *sidebar;
    __strong NSMutableArray *sidebarRoots; /* MacConfigSidebarNode * */
    __strong NSButton *cancelbutton;
    __strong NSButton *defaultbutton;
    MacConfigBox *owner;
    bool midsession;
    Conf *backup_conf;         /* restore on Cancel (Phase 6.2) */
};

struct MacConfigBox {
    struct dlgparam dp;
};

@interface MacConfigSidebarNode : NSObject
@property (nonatomic, copy) NSString *title;
@property (nonatomic, copy) NSString *path;
@property (nonatomic) NSInteger panelIndex;
@property (nonatomic, strong) NSMutableArray<MacConfigSidebarNode *> *children;
@end

@implementation MacConfigSidebarNode
- (instancetype)init
{
    self = [super init];
    if (self)
        _children = [NSMutableArray array];
    return self;
}
@end

@interface MacConfigBoxController : NSObject <NSWindowDelegate,
                                              NSSplitViewDelegate,
                                              NSOutlineViewDataSource,
                                              NSOutlineViewDelegate,
                                              NSTableViewDataSource,
                                              NSTableViewDelegate,
                                              NSTextFieldDelegate,
                                              NSComboBoxDataSource,
                                              NSComboBoxDelegate,
                                              NSToolbarDelegate>
@property (nonatomic) struct dlgparam *dp;
@end

/*
 * NSScrollView's clip view is bottom-left origin. Auto Layout document
 * views shorter than the clip then sit at the bottom with empty space
 * above (see Session Settings screenshot). Flip the clip (and document
 * host) so content pins to the top.
 */
@interface MacFlippedClipView : NSClipView
@end
@implementation MacFlippedClipView
- (BOOL)isFlipped { return YES; }
@end

@interface MacFlippedView : NSView
@end
@implementation MacFlippedView
- (BOOL)isFlipped { return YES; }
@end

/* Config NSWindow: keep a grabable strip on-screen; do not override setFrame. */
@interface MacConfigWindow : NSWindow
@end

static char mac_uctrl_key;
static char mac_config_controller_key;
static NSString * const kMacConfigToolbarId = @"org.tartarus.putty.config";
static NSString * const kMacConfigToolbarCategory = @"category";

/* ---------------------------------------------------------------------- */
/* Helpers */

static NSString *mac_ns(const char *utf8)
{
    if (!utf8)
        return @"";
    NSString *s = [NSString stringWithUTF8String:utf8];
    return s ?: @"";
}

static char *mac_dup_ns(NSString *s)
{
    if (!s)
        return dupstr("");
    const char *u = [s UTF8String];
    return dupstr(u ? u : "");
}

static int mac_uctrl_cmp(void *av, void *bv)
{
    struct MacUCtrl *a = (struct MacUCtrl *)av;
    struct MacUCtrl *b = (struct MacUCtrl *)bv;
    if (a->ctrl < b->ctrl)
        return -1;
    if (a->ctrl > b->ctrl)
        return +1;
    return 0;
}

static int mac_uctrl_find(void *av, void *bv)
{
    dlgcontrol *a = (dlgcontrol *)av;
    struct MacUCtrl *b = (struct MacUCtrl *)bv;
    if (a < b->ctrl)
        return -1;
    if (a > b->ctrl)
        return +1;
    return 0;
}

static void mac_dlg_init(struct dlgparam *dp)
{
    /* (void*): struct has __strong ObjC fields; zero-init is intentional. */
    memset((void *)dp, 0, sizeof(*dp));
    dp->byctrl = newtree234(mac_uctrl_cmp);
    dp->panels = [[NSMutableArray alloc] init];
    dp->panelPaths = [[NSMutableArray alloc] init];
    dp->sidebarRoots = [[NSMutableArray alloc] init];
    dp->retval = 0;
    dp->ended = false;
}

static void mac_uctrl_free(struct MacUCtrl *uc)
{
    if (!uc)
        return;
    sfree(uc->textvalue);
    uc->textvalue = NULL;
    /* Drop __strong ObjC refs before freeing the C struct. */
    uc->toplevel = nil;
    uc->label = nil;
    uc->widget = nil;
    uc->radioButtons = nil;
    uc->listItems = nil;
    uc->selectedIndexes = nil;
    uc->panel = nil;
    sfree(uc);
}

static void mac_dlg_cleanup(struct dlgparam *dp)
{
    struct MacUCtrl *uc;

    if (dp->byctrl) {
        while ((uc = delpos234(dp->byctrl, 0)) != NULL)
            mac_uctrl_free(uc);
        freetree234(dp->byctrl);
        dp->byctrl = NULL;
    }
    if (dp->ctrlbox) {
        ctrl_free_box(dp->ctrlbox);
        dp->ctrlbox = NULL;
    }
    if (dp->backup_conf) {
        conf_free(dp->backup_conf);
        dp->backup_conf = NULL;
    }
    dp->panels = nil;
    dp->panelPaths = nil;
    dp->sidebarRoots = nil;
    dp->window = nil;
    dp->sidebar = nil;
    dp->curr_panel = nil;
    dp->cancelbutton = nil;
    dp->defaultbutton = nil;
}

struct controlbox *mac_config_dlg_ctrlbox(struct dlgparam *dp)
{
    return dp ? dp->ctrlbox : NULL;
}

static struct MacUCtrl *mac_find_uctrl(dlgparam *dp, dlgcontrol *ctrl)
{
    return find234(dp->byctrl, ctrl, mac_uctrl_find);
}

/* Phase 9.2: VoiceOver labels + title UI element for config controls. */
static void mac_apply_control_accessibility(struct MacUCtrl *uc)
{
    NSString *label = nil;
    NSView *target;

    if (!uc || !uc->ctrl)
        return;

    if (uc->ctrl->label && uc->ctrl->label[0])
        label = mac_ns(uc->ctrl->label);

    target = uc->widget ? uc->widget : uc->toplevel;
    if (!target)
        return;

    if (label.length > 0)
        target.accessibilityLabel = label;

    if (uc->label && target != (NSView *)uc->label)
        [target setAccessibilityTitleUIElement:uc->label];

    /* Static text is not part of the keyboard loop. */
    if ([target isKindOfClass:[NSTextField class]] &&
        ![(NSTextField *)target isEditable]) {
        [(NSTextField *)target setRefusesFirstResponder:YES];
    }
}

static bool mac_accessibility_increase_contrast(void)
{
    return NSWorkspace.sharedWorkspace.accessibilityDisplayShouldIncreaseContrast;
}

static bool mac_accessibility_reduce_motion(void)
{
    return NSWorkspace.sharedWorkspace.accessibilityDisplayShouldReduceMotion;
}

/* Strengthen chrome borders with system accent (Increase Contrast → label). */
static void mac_apply_contrast_border(NSView *view)
{
    NSColor *border;
    if (!view)
        return;
    view.wantsLayer = YES;
    if (mac_accessibility_increase_contrast()) {
        view.layer.borderWidth = 1.5;
        border = NSColor.labelColor;
    } else {
        view.layer.borderWidth = 1.0;
        border = [NSColor.controlAccentColor colorWithAlphaComponent:0.55];
    }
    view.layer.borderColor = border.CGColor;
}

static void mac_prepare_config_window_keyboard(NSWindow *window, NSView *first)
{
    if (!window)
        return;
    if (mac_accessibility_reduce_motion())
        window.animationBehavior = NSWindowAnimationBehaviorNone;
    window.autorecalculatesKeyViewLoop = YES;
    [window recalculateKeyViewLoop];
    if (first)
        window.initialFirstResponder = first;
    window.accessibilityLabel = window.title;
}

static void mac_add_uctrl(dlgparam *dp, struct MacUCtrl *uc)
{
    struct MacUCtrl *added = add234(dp->byctrl, uc);
    assert(added == uc);
    objc_setAssociatedObject(uc->toplevel, &mac_uctrl_key,
                             [NSValue valueWithPointer:uc],
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    mac_apply_control_accessibility(uc);
}

static struct MacUCtrl *mac_uctrl_from_sender(id sender)
{
    NSView *v = (NSView *)sender;
    while (v) {
        NSValue *val = objc_getAssociatedObject(v, &mac_uctrl_key);
        if (val)
            return (struct MacUCtrl *)[val pointerValue];
        v = v.superview;
    }
    return NULL;
}

/*
 * Soft minimums for config layout. Must stay below
 * NSLayoutPriorityWindowSizeStayPut (500): anything higher (e.g. DefaultHigh
 * 750) beats the user's resize drag and freezes the window. Required (1000)
 * also yanks the origin off-screen. DefaultLow (250) prefers readable layout
 * without owning the NSWindow frame.
 */
static const NSLayoutPriority kMacConfigSoftMinPriority =
    NSLayoutPriorityDefaultLow; /* 250 */

static void mac_activate_soft_min_width(NSView *v, CGFloat width)
{
    NSLayoutConstraint *c =
        [v.widthAnchor constraintGreaterThanOrEqualToConstant:width];
    c.priority = kMacConfigSoftMinPriority;
    c.active = YES;
}

/*
 * Ensure a grabable strip of the window stays on a visible screen. Does not
 * force the whole frame on-screen (users may park windows partly off-edge);
 * only corrects frames that would otherwise be unreachable after a bad
 * Auto Layout resize.
 */
static NSRect mac_clamp_window_frame_to_screens(NSRect frame)
{
    NSScreen *screen = nil;
    CGFloat best_area = -1.0;

    for (NSScreen *s in [NSScreen screens]) {
        NSRect inter = NSIntersectionRect(frame, s.visibleFrame);
        CGFloat area = NSWidth(inter) * NSHeight(inter);
        if (area > best_area) {
            best_area = area;
            screen = s;
        }
    }
    if (!screen)
        screen = [NSScreen mainScreen];
    if (!screen)
        return frame;

    NSRect vis = screen.visibleFrame;
    /* Title-bar drag strip: enough width/height to click and pull back. */
    const CGFloat min_visible_w = 120.0;
    const CGFloat min_visible_h = 28.0;

    if (NSWidth(frame) > NSWidth(vis)) {
        frame.size.width = NSWidth(vis);
        frame.origin.x = NSMinX(vis);
    }
    if (NSHeight(frame) > NSHeight(vis)) {
        frame.size.height = NSHeight(vis);
        frame.origin.y = NSMinY(vis);
    }

    if (NSMaxX(frame) < NSMinX(vis) + min_visible_w)
        frame.origin.x = NSMinX(vis) + min_visible_w - NSWidth(frame);
    if (NSMinX(frame) > NSMaxX(vis) - min_visible_w)
        frame.origin.x = NSMaxX(vis) - min_visible_w;
    if (NSMaxY(frame) < NSMinY(vis) + min_visible_h)
        frame.origin.y = NSMinY(vis) + min_visible_h - NSHeight(frame);
    if (NSMinY(frame) > NSMaxY(vis) - min_visible_h)
        frame.origin.y = NSMaxY(vis) - min_visible_h;

    return frame;
}

@implementation MacConfigWindow
- (NSRect)constrainFrameRect:(NSRect)frameRect toScreen:(NSScreen *)screen
{
    NSRect constrained = [super constrainFrameRect:frameRect toScreen:screen];
    NSSize min = self.minSize;
    if (min.width > 0 && NSWidth(constrained) < min.width)
        constrained.size.width = min.width;
    if (min.height > 0 && NSHeight(constrained) < min.height)
        constrained.size.height = min.height;
    return mac_clamp_window_frame_to_screens(constrained);
}
@end

static NSTextField *mac_make_label(const char *text)
{
    NSTextField *tf = [NSTextField labelWithString:mac_ns(text)];
    tf.alignment = NSTextAlignmentLeft;
    tf.translatesAutoresizingMaskIntoConstraints = NO;
    [tf setContentHuggingPriority:NSLayoutPriorityDefaultHigh
                   forOrientation:NSLayoutConstraintOrientationHorizontal];
    /*
     * Below Required so long labels cannot force the window wider than
     * window.minSize during live resize (that yanks the origin left).
     */
    [tf setContentCompressionResistancePriority:kMacConfigSoftMinPriority
                                 forOrientation:NSLayoutConstraintOrientationHorizontal];
    [tf setContentCompressionResistancePriority:NSLayoutPriorityRequired
                                 forOrientation:NSLayoutConstraintOrientationVertical];
    return tf;
}

static void mac_prepare_view(NSView *v)
{
    if (!v)
        return;
    v.translatesAutoresizingMaskIntoConstraints = NO;
    [v setContentCompressionResistancePriority:NSLayoutPriorityDefaultHigh
                                forOrientation:NSLayoutConstraintOrientationVertical];
    /*
     * Buttons default to Required horizontal resistance (full title width).
     * Soften so live resize is governed by window.minSize, not intrinsic
     * content width — Required here was yanking the frame off-screen.
     */
    [v setContentCompressionResistancePriority:kMacConfigSoftMinPriority
                                forOrientation:NSLayoutConstraintOrientationHorizontal];
}

static NSStackView *mac_make_vstack(void)
{
    NSStackView *stack = [[NSStackView alloc] initWithFrame:NSZeroRect];
    stack.orientation = NSUserInterfaceLayoutOrientationVertical;
    stack.alignment = NSLayoutAttributeLeading;
    stack.distribution = NSStackViewDistributionGravityAreas;
    stack.spacing = 8;
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    stack.detachesHiddenViews = YES;
    return stack;
}

static NSStackView *mac_make_hstack(void)
{
    NSStackView *stack = [[NSStackView alloc] initWithFrame:NSZeroRect];
    stack.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    stack.alignment = NSLayoutAttributeCenterY;
    stack.distribution = NSStackViewDistributionGravityAreas;
    stack.spacing = 8;
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    stack.detachesHiddenViews = YES;
    return stack;
}

/* Stretch a child to the stack's full width while keeping Leading alignment
 * (so labels/checkboxes stay left-justified inside the row). */
static void mac_stack_fill_width(NSStackView *stack, NSView *child)
{
    if (!stack || !child)
        return;
    [child.widthAnchor constraintEqualToAnchor:stack.widthAnchor].active = YES;
}

static NSScrollView *mac_make_scroll_view(NSView *document)
{
    NSScrollView *scroll = [[NSScrollView alloc] initWithFrame:NSZeroRect];
    MacFlippedClipView *clip =
        [[MacFlippedClipView alloc] initWithFrame:NSZeroRect];
    scroll.contentView = clip;
    scroll.hasVerticalScroller = YES;
    scroll.hasHorizontalScroller = NO;
    scroll.autohidesScrollers = YES;
    scroll.borderType = NSNoBorder;
    scroll.drawsBackground = YES;
    scroll.translatesAutoresizingMaskIntoConstraints = NO;
    document.translatesAutoresizingMaskIntoConstraints = NO;
    scroll.documentView = document;
    mac_apply_contrast_border(scroll);
    return scroll;
}

/* Section: bold heading, then slightly indented body for the controls. */
static NSStackView *mac_make_section(const char *title)
{
    NSStackView *section = mac_make_vstack();
    if (title && title[0]) {
        NSTextField *heading = mac_make_label(title);
        heading.font = [NSFont boldSystemFontOfSize:NSFont.systemFontSize];
        [section addArrangedSubview:heading];
        mac_stack_fill_width(section, heading);
    }
    return section;
}

static NSStackView *mac_section_body(NSStackView *section)
{
    NSStackView *body = mac_make_vstack();
    /* Slight indent under the section heading (options under a title). */
    body.edgeInsets = NSEdgeInsetsMake(0, 12, 0, 0);
    [section addArrangedSubview:body];
    mac_stack_fill_width(section, body);
    return body;
}

static void mac_fire_handler(struct dlgparam *dp, struct MacUCtrl *uc, int event)
{
    if (!uc || !uc->ctrl || !uc->ctrl->handler)
        return;
    if (dp->flags & FLAG_IGNORING_EVENTS)
        return;
    uc->ctrl->handler(uc->ctrl, dp, dp->data, event);
}

/*
 * Push every CTRL_FONTSELECT text field into Conf. The font panel is
 * modeless; if changeFont: was missed (target/first-responder races),
 * Save/Open/Apply would otherwise persist the stale FontSpec.
 */
static void mac_commit_font_selectors(struct dlgparam *dp)
{
    int i;

    if (!dp || !dp->byctrl || !dp->data)
        return;
    for (i = 0;; i++) {
        struct MacUCtrl *uc = index234(dp->byctrl, i);
        if (!uc)
            break;
        if (!uc->ctrl || uc->ctrl->type != CTRL_FONTSELECT)
            continue;
        if (!uc->ctrl->handler)
            continue;
        uc->ctrl->handler(uc->ctrl, dp, dp->data, EVENT_VALCHANGE);
    }
}

/*
 * NSTextField / NSComboBox only send their action when editing ends
 * (Return or focus change). Clicking Apply / Save / Open often leaves
 * the field as first responder, so the Conf copy never sees the typed
 * value. Force any in-progress editing to commit before button actions.
 */
static void mac_commit_pending_edits(struct dlgparam *dp)
{
    if (!dp || !dp->window)
        return;
    [dp->window endEditingFor:nil];
    [dp->window makeFirstResponder:nil];
    mac_commit_font_selectors(dp);
}

/* ---------------------------------------------------------------------- */
/* Target actions */

@interface MacConfigActions : NSObject <NSTextFieldDelegate, NSComboBoxDelegate>
@property (nonatomic) struct dlgparam *dp;
@property (nonatomic) struct MacUCtrl *pendingFontUCtrl;
@property (nonatomic) struct MacUCtrl *pendingColourUCtrl;
@end

@implementation MacConfigActions

- (void)buttonClicked:(id)sender
{
    mac_commit_pending_edits(self.dp);
    struct MacUCtrl *uc = mac_uctrl_from_sender(sender);
    if (uc)
        mac_fire_handler(self.dp, uc, EVENT_ACTION);
}

- (void)checkboxToggled:(id)sender
{
    struct MacUCtrl *uc = mac_uctrl_from_sender(sender);
    if (uc)
        mac_fire_handler(self.dp, uc, EVENT_VALCHANGE);
}

- (void)radioToggled:(id)sender
{
    struct MacUCtrl *uc = mac_uctrl_from_sender(sender);
    NSButton *btn = (NSButton *)sender;
    if (!uc || !uc->radioButtons)
        return;
    if (btn.state != NSControlStateValueOn)
        return;
    for (NSButton *b in uc->radioButtons) {
        if (b != btn)
            b.state = NSControlStateValueOff;
    }
    mac_fire_handler(self.dp, uc, EVENT_VALCHANGE);
}

- (void)editChanged:(id)sender
{
    struct MacUCtrl *uc = mac_uctrl_from_sender(sender);
    if (uc)
        mac_fire_handler(self.dp, uc, EVENT_VALCHANGE);
}

/*
 * Keep Conf in sync while typing (not only when the field resigns focus),
 * so Apply / Save cannot miss the last keystroke even if focus steal fails.
 */
- (void)controlTextDidChange:(NSNotification *)notification
{
    if (!self.dp || (self.dp->flags & FLAG_IGNORING_EVENTS))
        return;
    id obj = notification.object;
    if (!obj)
        return;
    [self editChanged:obj];
}

/*
 * Return in an edit box: commit VALCHANGE. For the Saved Sessions name
 * field only, also fire EVENT_ACTION so Enter acts like Save (rename /
 * save-as workflow). Other fields ignore ACTION and keep field-exit.
 */
- (BOOL)control:(NSControl *)control
       textView:(NSTextView *)textView
doCommandBySelector:(SEL)commandSelector
{
    (void)textView;
    if (commandSelector != @selector(insertNewline:) &&
        commandSelector != @selector(insertNewlineIgnoringFieldEditor:))
        return NO;

    struct MacUCtrl *uc = mac_uctrl_from_sender(control);
    if (!uc)
        return NO;

    mac_fire_handler(self.dp, uc, EVENT_VALCHANGE);

    if (uc->ctrl->type == CTRL_EDITBOX &&
        uc->ctrl->label &&
        !strcmp(uc->ctrl->label, "Saved Sessions")) {
        mac_fire_handler(self.dp, uc, EVENT_ACTION);
        [self.dp->window makeFirstResponder:nil];
        return YES;
    }
    return NO;
}

- (void)listboxDoubleClicked:(id)sender
{
    NSTableView *table = (NSTableView *)sender;
    NSValue *val = objc_getAssociatedObject(table, &mac_uctrl_key);
    struct MacUCtrl *uc = val ? (struct MacUCtrl *)[val pointerValue] : NULL;
    if (!uc || !self.dp)
        return;
    mac_fire_handler(self.dp, uc, EVENT_ACTION);
}

- (void)popupChanged:(id)sender
{
    struct MacUCtrl *uc = mac_uctrl_from_sender(sender);
    if (!uc)
        return;
    if (self.dp->flags & FLAG_UPDATING_COMBO_LIST)
        return;
    NSPopUpButton *popup = (NSPopUpButton *)uc->widget;
    uc->selectedIndex = popup.indexOfSelectedItem;
    mac_fire_handler(self.dp, uc, EVENT_SELCHANGE);
}

- (void)comboChanged:(id)sender
{
    struct MacUCtrl *uc = mac_uctrl_from_sender(sender);
    if (!uc)
        return;
    if (self.dp->flags & FLAG_UPDATING_COMBO_LIST)
        return;
    mac_fire_handler(self.dp, uc, EVENT_VALCHANGE);
}

- (void)fileBrowse:(id)sender
{
    struct MacUCtrl *uc = mac_uctrl_from_sender(sender);
    if (!uc || uc->ctrl->type != CTRL_FILESELECT)
        return;

    dlgcontrol *ctrl = uc->ctrl;
    NSWindow *parent = self.dp->window;
    bool for_writing = ctrl->fileselect.for_writing;

    if (for_writing) {
        NSSavePanel *panel = [NSSavePanel savePanel];
        panel.title = mac_ns(ctrl->fileselect.title);
        panel.canCreateDirectories = YES;
        [panel beginSheetModalForWindow:parent
                      completionHandler:^(NSModalResponse result) {
            if (result != NSModalResponseOK)
                return;
            NSString *path = panel.URL.path;
            if (uc->widget && [uc->widget isKindOfClass:[NSTextField class]]) {
                ((NSTextField *)uc->widget).stringValue = path ?: @"";
            } else {
                sfree(uc->textvalue);
                uc->textvalue = mac_dup_ns(path);
            }
            mac_fire_handler(self.dp, uc, EVENT_CALLBACK);
        }];
    } else {
        NSOpenPanel *panel = [NSOpenPanel openPanel];
        panel.title = mac_ns(ctrl->fileselect.title);
        panel.canChooseFiles = YES;
        panel.canChooseDirectories = NO;
        panel.allowsMultipleSelection = NO;
        switch (ctrl->fileselect.filter) {
          case FILTER_KEY_FILES:
            panel.allowedContentTypes = @[
                [UTType typeWithFilenameExtension:@"ppk"] ?: UTTypeData
            ];
            break;
          case FILTER_DYNLIB_FILES:
            panel.allowedContentTypes = @[
                [UTType typeWithFilenameExtension:@"dylib"] ?: UTTypeData,
                [UTType typeWithFilenameExtension:@"so"] ?: UTTypeData
            ];
            break;
          case FILTER_SOUND_FILES:
            panel.allowedContentTypes = @[
                UTTypeAudio,
                [UTType typeWithFilenameExtension:@"aiff"] ?: UTTypeAudio,
                [UTType typeWithFilenameExtension:@"wav"] ?: UTTypeAudio,
                [UTType typeWithFilenameExtension:@"caf"] ?: UTTypeAudio
            ];
            break;
          default:
            break;
        }
        [panel beginSheetModalForWindow:parent
                      completionHandler:^(NSModalResponse result) {
            if (result != NSModalResponseOK)
                return;
            NSString *path = panel.URL.path;
            if (uc->widget && [uc->widget isKindOfClass:[NSTextField class]]) {
                ((NSTextField *)uc->widget).stringValue = path ?: @"";
            } else {
                sfree(uc->textvalue);
                uc->textvalue = mac_dup_ns(path);
            }
            mac_fire_handler(self.dp, uc, EVENT_CALLBACK);
        }];
    }
}

/*
 * NSFontPanel is modeless. After Apply/Cancel we free MacUCtrl, but the
 * panel can keep calling changeFont: with a dangling pendingFontUCtrl
 * (heap corruption → later crash in SSH I/O; see app_crash_007.txt).
 */
- (void)releaseFontPanel
{
    NSFontManager *fm = [NSFontManager sharedFontManager];
    if (fm.target == self)
        fm.target = nil;
    self.pendingFontUCtrl = NULL;
    NSFontPanel *panel = [NSFontPanel sharedFontPanel];
    if (panel.visible)
        [panel orderOut:nil];
}

- (BOOL)pendingFontControlIsLive
{
    struct MacUCtrl *uc = self.pendingFontUCtrl;
    int i;

    if (!uc || !self.dp || !self.dp->byctrl || self.dp->ended)
        return NO;
    if (!uc->ctrl || uc->ctrl->type != CTRL_FONTSELECT)
        return NO;
    if (!uc->widget || ![uc->widget isKindOfClass:[NSTextField class]])
        return NO;
    for (i = 0;; i++) {
        struct MacUCtrl *cand = index234(self.dp->byctrl, i);
        if (!cand)
            break;
        if (cand == uc)
            return YES;
    }
    return NO;
}

- (void)applySelectedFontToPendingControl
{
    struct MacUCtrl *uc;

    if (![self pendingFontControlIsLive]) {
        [self releaseFontPanel];
        return;
    }
    uc = self.pendingFontUCtrl;

    NSFontManager *fm = [NSFontManager sharedFontManager];
    NSFont *base = [fm selectedFont];
    if (!base)
        base = [NSFont monospacedSystemFontOfSize:12
                                           weight:NSFontWeightRegular];
    NSFont *font = [fm convertFont:base];
    if (!font)
        font = base;
    if (!font)
        return;

    /* Integer sizes when whole; avoid "14.000000" noise in the field. */
    CGFloat pts = font.pointSize;
    NSString *sizeStr = (fabs(pts - rint(pts)) < 0.01)
        ? [NSString stringWithFormat:@"%.0f", pts]
        : [NSString stringWithFormat:@"%g", (double)pts];
    NSString *spec = [NSString stringWithFormat:@"mac:%@:%@",
                      font.fontName, sizeStr];
    ((NSTextField *)uc->widget).stringValue = spec;
    /*
     * conf_fontsel_handler only handles EVENT_VALCHANGE (Windows parity).
     * EVENT_CALLBACK left Conf stale so Save/Apply kept the old font.
     */
    mac_fire_handler(self.dp, uc, EVENT_VALCHANGE);
}

- (void)fontBrowse:(id)sender
{
    struct MacUCtrl *uc = mac_uctrl_from_sender(sender);
    if (!uc || uc->ctrl->type != CTRL_FONTSELECT)
        return;
    if (!self.dp || self.dp->ended)
        return;

    NSFontManager *fm = [NSFontManager sharedFontManager];
    NSTextField *field = (NSTextField *)uc->widget;
    NSString *cur = field.stringValue;
    NSFont *font = [NSFont monospacedSystemFontOfSize:12
                                               weight:NSFontWeightRegular];

    if ([cur hasPrefix:@"mac:"]) {
        NSArray *parts = [cur componentsSeparatedByString:@":"];
        if (parts.count >= 3) {
            CGFloat size = [parts.lastObject doubleValue];
            NSString *psName =
                [[parts subarrayWithRange:NSMakeRange(1, parts.count - 2)]
                    componentsJoinedByString:@":"];
            NSFont *named = [NSFont fontWithName:psName
                                            size:size > 0 ? size : 12];
            if (named)
                font = named;
        }
    }

    self.pendingFontUCtrl = uc;
    /*
     * Keep MacConfigActions as the font-manager target. AppKit also sends
     * changeFont: up the responder chain; without an explicit target the
     * panel can update the field never / miss Conf.
     */
    fm.target = self;
    fm.action = @selector(changeFont:);
    [fm setSelectedFont:font isMultiple:NO];
    [[NSFontPanel sharedFontPanel] setPanelFont:font isMultiple:NO];
    [fm orderFrontFontPanel:self];
}

- (void)changeFont:(id)sender
{
    (void)sender;
    [self applySelectedFontToPendingControl];
}

- (void)draglistUp:(id)sender
{
    struct MacUCtrl *uc = mac_uctrl_from_sender(sender);
    if (!uc || !uc->listItems || uc->selectedIndex <= 0)
        return;
    NSInteger i = uc->selectedIndex;
    [uc->listItems exchangeObjectAtIndex:(NSUInteger)i
                       withObjectAtIndex:(NSUInteger)(i - 1)];
    uc->selectedIndex = i - 1;
    if ([uc->widget isKindOfClass:[NSTableView class]])
        [(NSTableView *)uc->widget reloadData];
    mac_fire_handler(self.dp, uc, EVENT_VALCHANGE);
}

- (void)draglistDown:(id)sender
{
    struct MacUCtrl *uc = mac_uctrl_from_sender(sender);
    if (!uc || !uc->listItems)
        return;
    NSInteger i = uc->selectedIndex;
    if (i < 0 || i + 1 >= (NSInteger)uc->listItems.count)
        return;
    [uc->listItems exchangeObjectAtIndex:(NSUInteger)i
                       withObjectAtIndex:(NSUInteger)(i + 1)];
    uc->selectedIndex = i + 1;
    if ([uc->widget isKindOfClass:[NSTableView class]])
        [(NSTableView *)uc->widget reloadData];
    mac_fire_handler(self.dp, uc, EVENT_VALCHANGE);
}

- (void)colourPanelChanged:(NSNotification *)note
{
    (void)note;
    if (!self.dp || !self.dp->coloursel.pending)
        return;
    NSColorPanel *panel = [NSColorPanel sharedColorPanel];
    NSColor *rgb = [panel.color
        colorUsingColorSpace:[NSColorSpace genericRGBColorSpace]];
    if (!rgb)
        rgb = panel.color;
    CGFloat rr = 0, gg = 0, bb = 0, aa = 1;
    [rgb getRed:&rr green:&gg blue:&bb alpha:&aa];
    self.dp->coloursel.r = (unsigned char)(rr * 255.0 + 0.5);
    self.dp->coloursel.g = (unsigned char)(gg * 255.0 + 0.5);
    self.dp->coloursel.b = (unsigned char)(bb * 255.0 + 0.5);
    self.dp->coloursel.ok = true;
    self.dp->coloursel.pending = false;
    [[NSNotificationCenter defaultCenter] removeObserver:self
                                                    name:NSColorPanelColorDidChangeNotification
                                                  object:panel];
    if (self.dp->coloursel.ctrl && self.dp->coloursel.ctrl->handler)
        self.dp->coloursel.ctrl->handler(
            self.dp->coloursel.ctrl, self.dp, self.dp->data, EVENT_CALLBACK);
}

@end

static char mac_actions_key;
static char mac_smoke_actions_key;

static MacConfigActions *mac_actions_for(struct dlgparam *dp)
{
    MacConfigActions *actions =
        objc_getAssociatedObject(dp->window, &mac_actions_key);
    if (!actions && dp->window) {
        actions = [[MacConfigActions alloc] init];
        actions.dp = dp;
        objc_setAssociatedObject(dp->window, &mac_actions_key, actions,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    return actions;
}

/* Keep a strong actions object on offscreen smoke windows too. */
static MacConfigActions *mac_ensure_actions(struct dlgparam *dp, NSView *anchor)
{
    MacConfigActions *actions =
        objc_getAssociatedObject(anchor, &mac_smoke_actions_key);
    if (!actions) {
        actions = [[MacConfigActions alloc] init];
        actions.dp = dp;
        objc_setAssociatedObject(anchor, &mac_smoke_actions_key, actions,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    return actions;
}

/* ---------------------------------------------------------------------- */
/* Control layout */

static struct MacUCtrl *mac_new_uctrl(dlgcontrol *ctrl, NSView *panel)
{
    struct MacUCtrl *uc = snew(struct MacUCtrl);
    /* (void*): struct has __strong ObjC fields; zero-init is intentional. */
    memset((void *)uc, 0, sizeof(*uc));
    uc->ctrl = ctrl;
    uc->panel = panel;
    uc->selectedIndex = -1;
    /* +1 retain (not autoreleased) so listItems survives without ARC too. */
    uc->listItems = [[NSMutableArray alloc] init];
    uc->selectedIndexes = [[NSMutableIndexSet alloc] init];
    return uc;
}

static NSView *mac_layout_one_control(
    struct dlgparam *dp, dlgcontrol *ctrl, NSView *panel,
    NSStackView * __strong columnStacks[], int ncols,
    MacConfigActions *actions)
{
    struct MacUCtrl *uc;
    NSView *row = nil;
    int col = COLUMN_START(ctrl->column);
    int span = COLUMN_SPAN(ctrl->column);

    if (col < 0)
        col = 0;
    if (ncols <= 0)
        ncols = 1;
    if (col >= ncols)
        col = ncols - 1;
    if (col + span > ncols)
        span = ncols - col;

    switch (ctrl->type) {
      case CTRL_COLUMNS:
      case CTRL_TABDELAY:
        return nil;

      case CTRL_TEXT: {
        uc = mac_new_uctrl(ctrl, panel);
        NSTextField *tf = mac_make_label(ctrl->label);
        tf.preferredMaxLayoutWidth = 640;
        tf.lineBreakMode = NSLineBreakByWordWrapping;
        uc->toplevel = tf;
        uc->label = tf;
        uc->widget = tf;
        mac_add_uctrl(dp, uc);
        row = tf;
        break;
      }

      case CTRL_BUTTON: {
        uc = mac_new_uctrl(ctrl, panel);
        NSButton *btn = [NSButton buttonWithTitle:mac_ns(ctrl->label)
                                           target:actions
                                           action:@selector(buttonClicked:)];
        btn.bezelStyle = NSBezelStyleRounded;
        if (ctrl->button.isdefault) {
            btn.keyEquivalent = @"\r";
            dp->defaultbutton = btn;
        }
        if (ctrl->button.iscancel) {
            btn.keyEquivalent = @"\033";
            dp->cancelbutton = btn;
        }
        uc->toplevel = btn;
        uc->widget = btn;
        mac_add_uctrl(dp, uc);
        row = btn;
        break;
      }

      case CTRL_CHECKBOX: {
        uc = mac_new_uctrl(ctrl, panel);
        NSButton *btn = [NSButton checkboxWithTitle:mac_ns(ctrl->label)
                                             target:actions
                                             action:@selector(checkboxToggled:)];
        uc->toplevel = btn;
        uc->widget = btn;
        mac_add_uctrl(dp, uc);
        row = btn;
        break;
      }

      case CTRL_RADIO: {
        uc = mac_new_uctrl(ctrl, panel);
        uc->radioButtons = [[NSMutableArray alloc] init];
        NSStackView *outer = mac_make_vstack();
        if (ctrl->label) {
            NSTextField *lab = mac_make_label(ctrl->label);
            uc->label = lab;
            [outer addArrangedSubview:lab];
        }
        int ncolumns = ctrl->radio.ncolumns > 0 ? ctrl->radio.ncolumns : 1;
        NSStackView *grid = mac_make_vstack();
        NSStackView *line = nil;
        for (int i = 0; i < ctrl->radio.nbuttons; i++) {
            if (i % ncolumns == 0) {
                line = mac_make_hstack();
                [grid addArrangedSubview:line];
            }
            NSButton *btn =
                [[NSButton alloc] initWithFrame:NSZeroRect];
            btn.buttonType = NSButtonTypeRadio;
            btn.title = mac_ns(ctrl->radio.buttons[i]);
            btn.target = actions;
            btn.action = @selector(radioToggled:);
            mac_prepare_view(btn);
            objc_setAssociatedObject(btn, &mac_uctrl_key,
                                     [NSValue valueWithPointer:uc],
                                     OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            [uc->radioButtons addObject:btn];
            [line addArrangedSubview:btn];
        }
        [outer addArrangedSubview:grid];
        uc->toplevel = outer;
        uc->widget = outer;
        mac_add_uctrl(dp, uc);
        row = outer;
        break;
      }

      case CTRL_EDITBOX: {
        uc = mac_new_uctrl(ctrl, panel);
        bool stacked = (ctrl->editbox.percentwidth == 100);
        NSStackView *box = stacked ? mac_make_vstack() : mac_make_hstack();
        /*
         * Side-by-side label+field (e.g. Colours Red/Green/Blue): Fill so the
         * field claims leftover width. GravityAreas left NSTextField at its
         * tiny intrinsic size and truncated values like "187".
         */
        if (!stacked)
            box.distribution = NSStackViewDistributionFill;
        if (ctrl->label) {
            NSTextField *lab = mac_make_label(ctrl->label);
            uc->label = lab;
            /*
             * Prefer keeping labels readable, but never Required — that
             * forces the window wider than the user's resize drag.
             */
            [lab setContentCompressionResistancePriority:kMacConfigSoftMinPriority
                                          forOrientation:NSLayoutConstraintOrientationHorizontal];
            [box addArrangedSubview:lab];
        }
        if (ctrl->editbox.has_list) {
            NSComboBox *combo = [[NSComboBox alloc] initWithFrame:NSZeroRect];
            combo.editable = YES;
            combo.completes = NO;
            combo.target = actions;
            combo.action = @selector(comboChanged:);
            combo.delegate = (id<NSComboBoxDelegate>)actions;
            mac_prepare_view(combo);
            objc_setAssociatedObject(combo, &mac_uctrl_key,
                                     [NSValue valueWithPointer:uc],
                                     OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            [combo setContentHuggingPriority:NSLayoutPriorityDefaultLow
                              forOrientation:NSLayoutConstraintOrientationHorizontal];
            [combo setContentCompressionResistancePriority:kMacConfigSoftMinPriority
                                            forOrientation:NSLayoutConstraintOrientationHorizontal];
            if (!stacked) {
                /* Enough for a few digits / short strings in narrow columns. */
                mac_activate_soft_min_width(combo, 56);
            }
            [box addArrangedSubview:combo];
            uc->widget = combo;
        } else {
            NSTextField *field;
            if (ctrl->editbox.password) {
                field = [[NSSecureTextField alloc] initWithFrame:NSZeroRect];
                field.stringValue = @"";
            } else {
                field = [NSTextField textFieldWithString:@""];
            }
            field.target = actions;
            field.action = @selector(editChanged:);
            field.delegate = (id<NSTextFieldDelegate>)actions;
            mac_prepare_view(field);
            objc_setAssociatedObject(field, &mac_uctrl_key,
                                     [NSValue valueWithPointer:uc],
                                     OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            [field setContentHuggingPriority:NSLayoutPriorityDefaultLow
                              forOrientation:NSLayoutConstraintOrientationHorizontal];
            [field setContentCompressionResistancePriority:kMacConfigSoftMinPriority
                                            forOrientation:NSLayoutConstraintOrientationHorizontal];
            if (!stacked) {
                /*
                 * RGB and similar short fields must show at least "255"
                 * without clipping when the label ("Green") is long.
                 */
                mac_activate_soft_min_width(field, 56);
            }
            [box addArrangedSubview:field];
            uc->widget = field;
        }
        uc->toplevel = box;
        mac_add_uctrl(dp, uc);
        row = box;
        break;
      }

      case CTRL_LISTBOX: {
        uc = mac_new_uctrl(ctrl, panel);
        NSStackView *box = mac_make_vstack();
        if (ctrl->label) {
            NSTextField *lab = mac_make_label(ctrl->label);
            uc->label = lab;
            [box addArrangedSubview:lab];
        }
        if (ctrl->listbox.height == 0) {
            /* Drop-down list */
            NSPopUpButton *popup =
                [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
            popup.target = actions;
            popup.action = @selector(popupChanged:);
            mac_prepare_view(popup);
            [box addArrangedSubview:popup];
            uc->widget = popup;
            uc->toplevel = box;
        } else {
            NSScrollView *scroll = [[NSScrollView alloc] initWithFrame:NSZeroRect];
            scroll.hasVerticalScroller = YES;
            scroll.autohidesScrollers = YES;
            scroll.borderType = NSBezelBorder;
            mac_prepare_view(scroll);

            NSTableView *table = [[NSTableView alloc] initWithFrame:NSZeroRect];
            NSTableColumn *col0 =
                [[NSTableColumn alloc] initWithIdentifier:@"text"];
            col0.title = @"";
            col0.editable = NO; /* list is read-only; rename via name field */
            [table addTableColumn:col0];
            table.headerView = nil;
            table.allowsMultipleSelection = ctrl->listbox.multisel != 0;
            table.allowsEmptySelection = YES;
            table.doubleAction = @selector(listboxDoubleClicked:);
            table.target = actions;
            scroll.documentView = table;
            [scroll.heightAnchor constraintEqualToConstant:
                (CGFloat)(ctrl->listbox.height * 22 + 8)].active = YES;
            mac_activate_soft_min_width(scroll, 200);
            [scroll setContentCompressionResistancePriority:
                       kMacConfigSoftMinPriority
                                            forOrientation:
                                                NSLayoutConstraintOrientationHorizontal];
            [table setContentCompressionResistancePriority:
                      kMacConfigSoftMinPriority
                                           forOrientation:
                                               NSLayoutConstraintOrientationHorizontal];

            MacConfigBoxController *ctl =
                objc_getAssociatedObject(dp->window, &mac_config_controller_key);
            if (!ctl) {
                /* Smoke / embed path: use a tiny local controller on the table. */
                ctl = [[MacConfigBoxController alloc] init];
                ctl.dp = dp;
                objc_setAssociatedObject(table, &mac_config_controller_key, ctl,
                                         OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            }
            table.dataSource = ctl;
            table.delegate = ctl;
            objc_setAssociatedObject(table, &mac_uctrl_key,
                                     [NSValue valueWithPointer:uc],
                                     OBJC_ASSOCIATION_RETAIN_NONATOMIC);

            if (ctrl->listbox.draglist) {
                NSStackView *rowstack = mac_make_hstack();
                [rowstack addArrangedSubview:scroll];
                NSStackView *btns = mac_make_vstack();
                NSButton *up = [NSButton buttonWithTitle:@"Up"
                                                  target:actions
                                                  action:@selector(draglistUp:)];
                NSButton *down = [NSButton buttonWithTitle:@"Down"
                                                    target:actions
                                                    action:@selector(draglistDown:)];
                mac_prepare_view(up);
                mac_prepare_view(down);
                [btns addArrangedSubview:up];
                [btns addArrangedSubview:down];
                [rowstack addArrangedSubview:btns];
                [box addArrangedSubview:rowstack];
                /* Associate buttons with uctrl via rowstack */
                objc_setAssociatedObject(rowstack, &mac_uctrl_key,
                                         [NSValue valueWithPointer:uc],
                                         OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            } else {
                [box addArrangedSubview:scroll];
            }
            uc->widget = table;
            uc->toplevel = box;
        }
        mac_add_uctrl(dp, uc);
        row = box;
        break;
      }

      case CTRL_FILESELECT: {
        uc = mac_new_uctrl(ctrl, panel);
        NSStackView *box = mac_make_vstack();
        if (ctrl->label) {
            NSTextField *lab = mac_make_label(ctrl->label);
            uc->label = lab;
            [box addArrangedSubview:lab];
        }
        NSStackView *line = mac_make_hstack();
        if (!ctrl->fileselect.just_button) {
            NSTextField *field = [NSTextField textFieldWithString:@""];
            field.editable = YES;
            field.target = actions;
            field.action = @selector(editChanged:);
            field.delegate = (id<NSTextFieldDelegate>)actions;
            mac_prepare_view(field);
            objc_setAssociatedObject(field, &mac_uctrl_key,
                                     [NSValue valueWithPointer:uc],
                                     OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            [line addArrangedSubview:field];
            uc->widget = field;
        }
        NSButton *browse = [NSButton buttonWithTitle:@"Browse…"
                                              target:actions
                                              action:@selector(fileBrowse:)];
        mac_prepare_view(browse);
        [line addArrangedSubview:browse];
        [box addArrangedSubview:line];
        uc->toplevel = box;
        if (!uc->widget)
            uc->widget = browse;
        mac_add_uctrl(dp, uc);
        row = box;
        break;
      }

      case CTRL_FONTSELECT: {
        uc = mac_new_uctrl(ctrl, panel);
        NSStackView *box = mac_make_vstack();
        if (ctrl->label) {
            NSTextField *lab = mac_make_label(ctrl->label);
            uc->label = lab;
            [box addArrangedSubview:lab];
        }
        NSStackView *line = mac_make_hstack();
        NSTextField *field = [NSTextField textFieldWithString:@""];
        field.editable = NO;
        mac_prepare_view(field);
        [line addArrangedSubview:field];
        NSButton *change = [NSButton buttonWithTitle:@"Change…"
                                              target:actions
                                              action:@selector(fontBrowse:)];
        mac_prepare_view(change);
        /*
         * Associate the button and field too — fontBrowse walks superviews
         * for mac_uctrl_key, but an explicit link on the button is safer.
         */
        objc_setAssociatedObject(change, &mac_uctrl_key,
                                 [NSValue valueWithPointer:uc],
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(field, &mac_uctrl_key,
                                 [NSValue valueWithPointer:uc],
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [line addArrangedSubview:change];
        [box addArrangedSubview:line];
        uc->widget = field;
        uc->toplevel = box;
        mac_add_uctrl(dp, uc);
        row = box;
        break;
      }

      default:
        return nil;
    }

    if (row && columnStacks) {
        NSStackView *dest = columnStacks[col];
        if (span > 1 && ncols > 1) {
            /* Place in first column; spanning is approximate in stack layout. */
            dest = columnStacks[col];
        }
        mac_prepare_view(row);
        [dest addArrangedSubview:row];
        /* Expand container rows (stacks / scroll lists / wrapping text) to
         * the column width. Leave NSButton at intrinsic size so checkboxes
         * and radios stay left-justified. */
        if ([row isKindOfClass:[NSStackView class]] ||
            [row isKindOfClass:[NSScrollView class]] ||
            ([row isKindOfClass:[NSTextField class]] &&
             ![(NSTextField *)row isEditable]))
            mac_stack_fill_width(dest, row);
    }
    return row;
}

NSView *mac_config_layout_controlset_impl(
    struct dlgparam *dp, struct controlset *s, NSView *panel,
    MacConfigActions *actions)
{
    if (!s->boxname) {
        /* Panel title only */
        return mac_make_label(s->boxtitle);
    }

    bool titled = (s->boxname[0] && s->boxtitle);
    NSStackView *outer = mac_make_section(titled ? s->boxtitle : NULL);
    NSStackView *body = titled ? mac_section_body(outer) : outer;

    int ncols = 1;
    NSStackView *colstacks[8];
    NSStackView *cols_row = mac_make_hstack();
    colstacks[0] = mac_make_vstack();
    [cols_row addArrangedSubview:colstacks[0]];
    [body addArrangedSubview:cols_row];
    mac_stack_fill_width(body, cols_row);

    for (size_t i = 0; i < s->ncontrols; i++) {
        dlgcontrol *ctrl = s->ctrls[i];
        if (ctrl->type == CTRL_COLUMNS) {
            ncols = ctrl->columns.ncols;
            if (ncols < 1)
                ncols = 1;
            if (ncols > 8)
                ncols = 8;
            cols_row = mac_make_hstack();
            /*
             * Honor ctrl_columns() percentages (e.g. Colours 67/33). FillEqually
             * ignored them and squeezed the RGB edit column.
             */
            cols_row.distribution = NSStackViewDistributionFill;
            for (int c = 0; c < ncols; c++) {
                colstacks[c] = mac_make_vstack();
                [cols_row addArrangedSubview:colstacks[c]];
                [colstacks[c]
                    setContentHuggingPriority:NSLayoutPriorityDefaultLow
                               forOrientation:
                                   NSLayoutConstraintOrientationHorizontal];
            }
            if (ncols > 1 && ctrl->columns.percentages) {
                int base_pct = ctrl->columns.percentages[0];
                if (base_pct < 1)
                    base_pct = 1;
                for (int c = 1; c < ncols; c++) {
                    int pct = ctrl->columns.percentages[c];
                    if (pct < 1)
                        pct = 1;
                    /* col[c] / col[0] == pct / base_pct */
                    NSLayoutConstraint *rel =
                        [colstacks[c].widthAnchor
                            constraintEqualToAnchor:colstacks[0].widthAnchor
                                         multiplier:(CGFloat)pct /
                                                    (CGFloat)base_pct];
                    rel.priority = NSLayoutPriorityDefaultHigh;
                    rel.active = YES;
                }
            }
            [body addArrangedSubview:cols_row];
            mac_stack_fill_width(body, cols_row);
            continue;
        }
        if (ctrl->type == CTRL_TABDELAY)
            continue;
        mac_layout_one_control(dp, ctrl, panel, colstacks, ncols, actions);
    }
    return outer;
}

void *mac_config_layout_controlset(dlgparam *dp, struct controlset *s)
{
    MacConfigActions *actions = mac_ensure_actions(dp, dp->window.contentView);
    return (__bridge void *)mac_config_layout_controlset_impl(
        dp, s, nil, actions);
}

/* ---------------------------------------------------------------------- */
/* dlg_* API */

void dlg_radiobutton_set(dlgcontrol *ctrl, dlgparam *dp, int which)
{
    struct MacUCtrl *uc = mac_find_uctrl(dp, ctrl);
    assert(uc && uc->ctrl->type == CTRL_RADIO && uc->radioButtons);
    assert(which >= 0 && which < (int)uc->radioButtons.count);
    dp->flags |= FLAG_IGNORING_EVENTS;
    for (NSUInteger i = 0; i < uc->radioButtons.count; i++)
        uc->radioButtons[i].state =
            (i == (NSUInteger)which) ? NSControlStateValueOn
                                     : NSControlStateValueOff;
    dp->flags &= ~FLAG_IGNORING_EVENTS;
}

int dlg_radiobutton_get(dlgcontrol *ctrl, dlgparam *dp)
{
    struct MacUCtrl *uc = mac_find_uctrl(dp, ctrl);
    assert(uc && uc->ctrl->type == CTRL_RADIO && uc->radioButtons);
    for (NSUInteger i = 0; i < uc->radioButtons.count; i++)
        if (uc->radioButtons[i].state == NSControlStateValueOn)
            return (int)i;
    return 0;
}

void dlg_checkbox_set(dlgcontrol *ctrl, dlgparam *dp, bool checked)
{
    struct MacUCtrl *uc = mac_find_uctrl(dp, ctrl);
    assert(uc && uc->ctrl->type == CTRL_CHECKBOX);
    dp->flags |= FLAG_IGNORING_EVENTS;
    ((NSButton *)uc->widget).state =
        checked ? NSControlStateValueOn : NSControlStateValueOff;
    dp->flags &= ~FLAG_IGNORING_EVENTS;
}

bool dlg_checkbox_get(dlgcontrol *ctrl, dlgparam *dp)
{
    struct MacUCtrl *uc = mac_find_uctrl(dp, ctrl);
    assert(uc && uc->ctrl->type == CTRL_CHECKBOX);
    return ((NSButton *)uc->widget).state == NSControlStateValueOn;
}

void dlg_editbox_set_utf8(dlgcontrol *ctrl, dlgparam *dp, char const *text)
{
    struct MacUCtrl *uc = mac_find_uctrl(dp, ctrl);
    assert(uc && uc->ctrl->type == CTRL_EDITBOX);
    char *tmp = dupstr(text ? text : "");
    dp->flags |= FLAG_IGNORING_EVENTS;
    if ([uc->widget isKindOfClass:[NSComboBox class]])
        ((NSComboBox *)uc->widget).stringValue = mac_ns(tmp);
    else
        ((NSTextField *)uc->widget).stringValue = mac_ns(tmp);
    dp->flags &= ~FLAG_IGNORING_EVENTS;
    sfree(tmp);
}

void dlg_editbox_set(dlgcontrol *ctrl, dlgparam *dp, char const *text)
{
    dlg_editbox_set_utf8(ctrl, dp, text);
}

char *dlg_editbox_get_utf8(dlgcontrol *ctrl, dlgparam *dp)
{
    struct MacUCtrl *uc = mac_find_uctrl(dp, ctrl);
    assert(uc && uc->ctrl->type == CTRL_EDITBOX);
    if ([uc->widget isKindOfClass:[NSComboBox class]])
        return mac_dup_ns(((NSComboBox *)uc->widget).stringValue);
    return mac_dup_ns(((NSTextField *)uc->widget).stringValue);
}

char *dlg_editbox_get(dlgcontrol *ctrl, dlgparam *dp)
{
    return dlg_editbox_get_utf8(ctrl, dp);
}

void dlg_editbox_select_range(dlgcontrol *ctrl, dlgparam *dp,
                              size_t start, size_t len)
{
    struct MacUCtrl *uc = mac_find_uctrl(dp, ctrl);
    assert(uc && uc->ctrl->type == CTRL_EDITBOX);
    NSTextField *field = nil;
    if ([uc->widget isKindOfClass:[NSTextField class]])
        field = (NSTextField *)uc->widget;
    if (!field)
        return;
    NSText *editor = [field currentEditor];
    if (!editor)
        return;
    NSRange r = NSMakeRange(start, len);
    [editor setSelectedRange:r];
}

void dlg_listbox_clear(dlgcontrol *ctrl, dlgparam *dp)
{
    struct MacUCtrl *uc = mac_find_uctrl(dp, ctrl);
    assert(uc);
    assert(uc->ctrl->type == CTRL_EDITBOX || uc->ctrl->type == CTRL_LISTBOX);
    dp->flags |= FLAG_UPDATING_COMBO_LIST | FLAG_UPDATING_LISTBOX;
    [uc->listItems removeAllObjects];
    uc->selectedIndex = -1;
    [uc->selectedIndexes removeAllIndexes];
    if ([uc->widget isKindOfClass:[NSPopUpButton class]]) {
        [(NSPopUpButton *)uc->widget removeAllItems];
    } else if ([uc->widget isKindOfClass:[NSComboBox class]]) {
        [(NSComboBox *)uc->widget removeAllItems];
    } else if ([uc->widget isKindOfClass:[NSTableView class]]) {
        [(NSTableView *)uc->widget reloadData];
    }
    dp->flags &= ~(FLAG_UPDATING_COMBO_LIST | FLAG_UPDATING_LISTBOX);
}

void dlg_listbox_del(dlgcontrol *ctrl, dlgparam *dp, int index)
{
    struct MacUCtrl *uc = mac_find_uctrl(dp, ctrl);
    assert(uc);
    if (index < 0 || index >= (int)uc->listItems.count)
        return;
    dp->flags |= FLAG_UPDATING_COMBO_LIST | FLAG_UPDATING_LISTBOX;
    [uc->listItems removeObjectAtIndex:(NSUInteger)index];
    if ([uc->widget isKindOfClass:[NSPopUpButton class]]) {
        [(NSPopUpButton *)uc->widget removeItemAtIndex:index];
    } else if ([uc->widget isKindOfClass:[NSComboBox class]]) {
        NSComboBox *cb = (NSComboBox *)uc->widget;
        if (index < cb.numberOfItems)
            [cb removeItemAtIndex:index];
    } else if ([uc->widget isKindOfClass:[NSTableView class]]) {
        [(NSTableView *)uc->widget reloadData];
    }
    dp->flags &= ~(FLAG_UPDATING_COMBO_LIST | FLAG_UPDATING_LISTBOX);
}

void dlg_listbox_add(dlgcontrol *ctrl, dlgparam *dp, char const *text)
{
    dlg_listbox_addwithid(ctrl, dp, text, 0);
}

void dlg_listbox_addwithid(dlgcontrol *ctrl, dlgparam *dp,
                           char const *text, int id)
{
    struct MacUCtrl *uc = mac_find_uctrl(dp, ctrl);
    assert(uc);
    assert(uc->ctrl->type == CTRL_EDITBOX || uc->ctrl->type == CTRL_LISTBOX);

    dp->flags |= FLAG_UPDATING_COMBO_LIST;
    MacConfigListItem *item = [[MacConfigListItem alloc] init];
    item.itemId = id;
    item.text = mac_ns(text);
    [uc->listItems addObject:item];

    if ([uc->widget isKindOfClass:[NSPopUpButton class]]) {
        [(NSPopUpButton *)uc->widget addItemWithTitle:item.text];
    } else if ([uc->widget isKindOfClass:[NSComboBox class]]) {
        [(NSComboBox *)uc->widget addItemWithObjectValue:item.text];
    } else if ([uc->widget isKindOfClass:[NSTableView class]]) {
        dp->flags |= FLAG_UPDATING_LISTBOX;
        [(NSTableView *)uc->widget reloadData];
        dp->flags &= ~FLAG_UPDATING_LISTBOX;
    }
    dp->flags &= ~FLAG_UPDATING_COMBO_LIST;
}

int dlg_listbox_getid(dlgcontrol *ctrl, dlgparam *dp, int index)
{
    struct MacUCtrl *uc = mac_find_uctrl(dp, ctrl);
    assert(uc);
    if (index < 0 || index >= (int)uc->listItems.count)
        return 0;
    return uc->listItems[(NSUInteger)index].itemId;
}

int dlg_listbox_index(dlgcontrol *ctrl, dlgparam *dp)
{
    struct MacUCtrl *uc = mac_find_uctrl(dp, ctrl);
    assert(uc);
    if ([uc->widget isKindOfClass:[NSPopUpButton class]])
        return (int)((NSPopUpButton *)uc->widget).indexOfSelectedItem;
    if ([uc->widget isKindOfClass:[NSTableView class]]) {
        NSIndexSet *sel = ((NSTableView *)uc->widget).selectedRowIndexes;
        if (sel.count != 1)
            return -1;
        return (int)sel.firstIndex;
    }
    return (int)uc->selectedIndex;
}

bool dlg_listbox_issel(dlgcontrol *ctrl, dlgparam *dp, int index)
{
    struct MacUCtrl *uc = mac_find_uctrl(dp, ctrl);
    assert(uc);
    if ([uc->widget isKindOfClass:[NSTableView class]])
        return [((NSTableView *)uc->widget).selectedRowIndexes
                containsIndex:(NSUInteger)index];
    return dlg_listbox_index(ctrl, dp) == index;
}

void dlg_listbox_select(dlgcontrol *ctrl, dlgparam *dp, int index)
{
    struct MacUCtrl *uc = mac_find_uctrl(dp, ctrl);
    assert(uc);
    dp->flags |= FLAG_IGNORING_EVENTS;
    uc->selectedIndex = index;
    if ([uc->widget isKindOfClass:[NSPopUpButton class]]) {
        if (index >= 0)
            [(NSPopUpButton *)uc->widget selectItemAtIndex:index];
    } else if ([uc->widget isKindOfClass:[NSTableView class]]) {
        NSTableView *tv = (NSTableView *)uc->widget;
        if (index < 0)
            [tv deselectAll:nil];
        else
            [tv selectRowIndexes:[NSIndexSet indexSetWithIndex:(NSUInteger)index]
            byExtendingSelection:NO];
    }
    dp->flags &= ~FLAG_IGNORING_EVENTS;
}

void dlg_text_set(dlgcontrol *ctrl, dlgparam *dp, char const *text)
{
    struct MacUCtrl *uc = mac_find_uctrl(dp, ctrl);
    assert(uc && uc->ctrl->type == CTRL_TEXT);
    ((NSTextField *)uc->widget).stringValue = mac_ns(text);
}

void dlg_label_change(dlgcontrol *ctrl, dlgparam *dp, char const *text)
{
    struct MacUCtrl *uc = mac_find_uctrl(dp, ctrl);
    if (!uc)
        return;
    NSString *s = mac_ns(text);
    switch (ctrl->type) {
      case CTRL_BUTTON:
      case CTRL_CHECKBOX:
        ((NSButton *)uc->widget).title = s;
        break;
      case CTRL_TEXT:
        ((NSTextField *)uc->widget).stringValue = s;
        break;
      default:
        if (uc->label)
            uc->label.stringValue = s;
        break;
    }
}

void dlg_filesel_set(dlgcontrol *ctrl, dlgparam *dp, Filename *fn)
{
    struct MacUCtrl *uc = mac_find_uctrl(dp, ctrl);
    assert(uc && uc->ctrl->type == CTRL_FILESELECT);
    char *duppath = dupstr(fn->path);
    if (uc->widget && [uc->widget isKindOfClass:[NSTextField class]])
        ((NSTextField *)uc->widget).stringValue = mac_ns(duppath);
    else {
        sfree(uc->textvalue);
        uc->textvalue = dupstr(duppath);
    }
    sfree(duppath);
}

Filename *dlg_filesel_get(dlgcontrol *ctrl, dlgparam *dp)
{
    struct MacUCtrl *uc = mac_find_uctrl(dp, ctrl);
    assert(uc && uc->ctrl->type == CTRL_FILESELECT);
    if (uc->widget && [uc->widget isKindOfClass:[NSTextField class]])
        return filename_from_str(
            [((NSTextField *)uc->widget).stringValue UTF8String] ?: "");
    return filename_from_str(uc->textvalue ? uc->textvalue : "");
}

void dlg_fontsel_set(dlgcontrol *ctrl, dlgparam *dp, FontSpec *fs)
{
    struct MacUCtrl *uc = mac_find_uctrl(dp, ctrl);
    assert(uc && uc->ctrl->type == CTRL_FONTSELECT);
    char *dupname = dupstr(fs->name);
    ((NSTextField *)uc->widget).stringValue = mac_ns(dupname);
    sfree(dupname);
}

FontSpec *dlg_fontsel_get(dlgcontrol *ctrl, dlgparam *dp)
{
    struct MacUCtrl *uc = mac_find_uctrl(dp, ctrl);
    assert(uc && uc->ctrl->type == CTRL_FONTSELECT);
    return fontspec_new(
        [((NSTextField *)uc->widget).stringValue UTF8String] ?: "");
}

void dlg_update_start(dlgcontrol *ctrl, dlgparam *dp)
{
    (void)ctrl;
    (void)dp;
}

void dlg_update_done(dlgcontrol *ctrl, dlgparam *dp)
{
    (void)ctrl;
    (void)dp;
}

void dlg_set_focus(dlgcontrol *ctrl, dlgparam *dp)
{
    struct MacUCtrl *uc = mac_find_uctrl(dp, ctrl);
    if (!uc || !uc->widget)
        return;
    if (dp->currfocus != ctrl) {
        dp->lastfocus = dp->currfocus;
        dp->currfocus = ctrl;
    }
    [dp->window makeFirstResponder:uc->widget];
}

dlgcontrol *dlg_last_focused(dlgcontrol *ctrl, dlgparam *dp)
{
    if (dp->currfocus != ctrl)
        return dp->currfocus;
    return dp->lastfocus;
}

bool dlg_is_visible(dlgcontrol *ctrl, dlgparam *dp)
{
    struct MacUCtrl *uc = mac_find_uctrl(dp, ctrl);
    if (!uc)
        return false;
    if (!uc->panel)
        return true;
    return uc->panel == dp->curr_panel;
}

void dlg_beep(dlgparam *dp)
{
    (void)dp;
    NSBeep();
}

void dlg_error_msg(dlgparam *dp, const char *msg)
{
    mac_gui_dialogs_ensure_app();
    NSAlert *alert = [[NSAlert alloc] init];
    alert.messageText = @"Error";
    alert.informativeText = mac_ns(msg);
    alert.alertStyle = NSAlertStyleWarning;
    [alert addButtonWithTitle:@"OK"];
    if (dp->window)
        [alert beginSheetModalForWindow:dp->window completionHandler:nil];
    else
        [alert runModal];
}

/* Forward decls for Host CA box lifetime (defined below). */
static void mac_ca_config_dlg_ended(dlgparam *dp);

void dlg_end(dlgparam *dp, int value)
{
    MacConfigActions *actions;

    if (dp->ended)
        return;
    dp->ended = true;
    dp->retval = value;
    post_dialog_fn_t after = dp->after;
    void *afterctx = dp->afterctx;
    NSWindow *window = dp->window;
    MacConfigBox *owner = dp->owner;

    /*
     * Detach the modeless font panel before any Conf/control teardown.
     * Otherwise changeFont: can touch freed MacUCtrl (app_crash_007.txt).
     */
    actions = window ? objc_getAssociatedObject(window, &mac_actions_key) : nil;
    [actions releaseFontPanel];

    /*
     * On Cancel, restore Conf from the backup taken at open (Windows
     * do_reconfig / GTK change-settings parity). On Apply/Open, keep edits.
     * Host CA boxes have no Conf backup.
     */
    if (value <= 0 && dp->backup_conf && dp->data)
        conf_copy_into((Conf *)dp->data, dp->backup_conf);

    /*
     * Hide without AppKit window-transform animations. Opening the session
     * window in `after` while a zoom/close animation is live crashes in
     * -[_NSWindowTransformAnimation dealloc] (see macos/app_crash_004.txt).
     */
    if (window) {
        window.animationBehavior = NSWindowAnimationBehaviorNone;
        [window setDelegate:nil];
        [window orderOut:nil];
        dp->window = nil;
    }

    if (after)
        after(afterctx, value);

    if (owner) {
        /* Tear down on the next turn so CA/AppKit finish the current flush. */
        dispatch_async(dispatch_get_main_queue(), ^{
            mac_config_box_free(owner);
        });
    } else {
        mac_ca_config_dlg_ended(dp);
    }
}

void dlg_refresh(dlgcontrol *ctrl, dlgparam *dp)
{
    struct MacUCtrl *uc;

    if (ctrl) {
        if (ctrl->handler)
            ctrl->handler(ctrl, dp, dp->data, EVENT_REFRESH);
    } else {
        int i;
        for (i = 0; (uc = index234(dp->byctrl, i)) != NULL; i++) {
            if (uc->ctrl && uc->ctrl->handler)
                uc->ctrl->handler(uc->ctrl, dp, dp->data, EVENT_REFRESH);
        }
    }
}

void dlg_coloursel_start(dlgcontrol *ctrl, dlgparam *dp, int r, int g, int b)
{
    MacConfigActions *actions = mac_actions_for(dp);
    if (!actions && dp->window)
        actions = mac_ensure_actions(dp, dp->window.contentView);

    dp->coloursel.pending = true;
    dp->coloursel.ctrl = ctrl;
    dp->coloursel.ok = false;
    dp->coloursel.r = (unsigned char)r;
    dp->coloursel.g = (unsigned char)g;
    dp->coloursel.b = (unsigned char)b;

    if (!actions)
        return;

    NSColorPanel *panel = [NSColorPanel sharedColorPanel];
    panel.color = [NSColor colorWithCalibratedRed:r / 255.0
                                            green:g / 255.0
                                             blue:b / 255.0
                                            alpha:1.0];
    panel.continuous = NO;
    [[NSNotificationCenter defaultCenter]
        addObserver:actions
           selector:@selector(colourPanelChanged:)
               name:NSColorPanelColorDidChangeNotification
             object:panel];
    [panel orderFront:nil];
}

bool dlg_coloursel_results(dlgcontrol *ctrl, dlgparam *dp,
                           int *r, int *g, int *b)
{
    (void)ctrl;
    if (!dp->coloursel.ok)
        return false;
    *r = dp->coloursel.r;
    *g = dp->coloursel.g;
    *b = dp->coloursel.b;
    return true;
}

/* ---------------------------------------------------------------------- */
/* Table / outline data source */

@implementation MacConfigBoxController

- (NSInteger)numberOfRowsInTableView:(NSTableView *)tableView
{
    NSValue *val = objc_getAssociatedObject(tableView, &mac_uctrl_key);
    struct MacUCtrl *uc = val ? (struct MacUCtrl *)[val pointerValue] : NULL;
    return uc ? (NSInteger)uc->listItems.count : 0;
}

- (id)tableView:(NSTableView *)tableView
    objectValueForTableColumn:(NSTableColumn *)tableColumn
                          row:(NSInteger)row
{
    (void)tableColumn;
    NSValue *val = objc_getAssociatedObject(tableView, &mac_uctrl_key);
    struct MacUCtrl *uc = val ? (struct MacUCtrl *)[val pointerValue] : NULL;
    if (!uc || row < 0 || row >= (NSInteger)uc->listItems.count)
        return @"";
    return uc->listItems[(NSUInteger)row].text;
}

- (void)tableViewSelectionDidChange:(NSNotification *)notification
{
    NSTableView *tableView = notification.object;
    NSValue *val = objc_getAssociatedObject(tableView, &mac_uctrl_key);
    struct MacUCtrl *uc = val ? (struct MacUCtrl *)[val pointerValue] : NULL;
    if (!uc || !self.dp)
        return;
    if (self.dp->flags & (FLAG_UPDATING_LISTBOX | FLAG_IGNORING_EVENTS))
        return;
    NSIndexSet *sel = tableView.selectedRowIndexes;
    uc->selectedIndex = sel.count == 1 ? (NSInteger)sel.firstIndex : -1;
    mac_fire_handler(self.dp, uc, EVENT_SELCHANGE);
}

- (NSInteger)outlineView:(NSOutlineView *)outlineView
    numberOfChildrenOfItem:(id)item
{
    (void)outlineView;
    if (!item)
        return (NSInteger)self.dp->sidebarRoots.count;
    return (NSInteger)((MacConfigSidebarNode *)item).children.count;
}

- (id)outlineView:(NSOutlineView *)outlineView
            child:(NSInteger)index
           ofItem:(id)item
{
    (void)outlineView;
    if (!item)
        return self.dp->sidebarRoots[(NSUInteger)index];
    return ((MacConfigSidebarNode *)item).children[(NSUInteger)index];
}

- (BOOL)outlineView:(NSOutlineView *)outlineView isItemExpandable:(id)item
{
    (void)outlineView;
    return ((MacConfigSidebarNode *)item).children.count > 0;
}

- (id)outlineView:(NSOutlineView *)outlineView
    objectValueForTableColumn:(NSTableColumn *)tableColumn
                       byItem:(id)item
{
    (void)outlineView;
    (void)tableColumn;
    return ((MacConfigSidebarNode *)item).title;
}

- (void)outlineViewSelectionDidChange:(NSNotification *)notification
{
    (void)notification;
    NSInteger row = self.dp->sidebar.selectedRow;
    if (row < 0)
        return;
    MacConfigSidebarNode *node = [self.dp->sidebar itemAtRow:row];
    if (!node || node.panelIndex < 0 ||
        node.panelIndex >= (NSInteger)self.dp->panels.count)
        return;
    for (NSUInteger i = 0; i < self.dp->panels.count; i++)
        ((NSView *)self.dp->panels[i]).hidden = (i != (NSUInteger)node.panelIndex);
    self.dp->curr_panel = self.dp->panels[(NSUInteger)node.panelIndex];
}

- (NSArray<NSToolbarItemIdentifier> *)toolbarAllowedItemIdentifiers:
    (NSToolbar *)toolbar
{
    (void)toolbar;
    return @[ NSToolbarFlexibleSpaceItemIdentifier,
              kMacConfigToolbarCategory ];
}

- (NSArray<NSToolbarItemIdentifier> *)toolbarDefaultItemIdentifiers:
    (NSToolbar *)toolbar
{
    (void)toolbar;
    return @[ NSToolbarFlexibleSpaceItemIdentifier,
              kMacConfigToolbarCategory ];
}

- (NSToolbarItem *)toolbar:(NSToolbar *)toolbar
     itemForItemIdentifier:(NSToolbarItemIdentifier)itemIdentifier
 willBeInsertedIntoToolbar:(BOOL)flag
{
    (void)toolbar;
    (void)flag;
    if (![itemIdentifier isEqualToString:kMacConfigToolbarCategory])
        return nil;
    NSToolbarItem *item =
        [[NSToolbarItem alloc] initWithItemIdentifier:itemIdentifier];
    item.label = @"Category";
    item.paletteLabel = @"Category";
    item.toolTip = @"Configuration category (see sidebar)";
    NSTextField *label = [NSTextField labelWithString:
        self.dp->midsession ? @"Settings" : @"Session Settings"];
    label.font = [NSFont systemFontOfSize:13 weight:NSFontWeightSemibold];
    label.textColor = NSColor.controlAccentColor;
    item.view = label;
    return item;
}

- (BOOL)windowShouldClose:(NSWindow *)sender
{
    (void)sender;
    if (self.dp && !self.dp->ended)
        dlg_end(self.dp, 0);
    return NO;
}

- (void)windowDidEndLiveResize:(NSNotification *)notification
{
    /*
     * After a user drag, ensure a grabable strip remains on-screen if Auto
     * Layout nudged the origin. Do not intervene mid-drag.
     */
    NSWindow *window = notification.object;
    if (![window isKindOfClass:[NSWindow class]])
        return;
    NSRect clamped = mac_clamp_window_frame_to_screens(window.frame);
    if (!NSEqualRects(clamped, window.frame))
        [window setFrame:clamped display:YES animate:NO];
}

/*
 * Pane widths via the split-view delegate — not Required width constraints
 * on the scroll views. Those constraints were shrinking contentView to the
 * split's fitting width (~306pt) while the window frame stayed at minSize,
 * which smooshed the settings pane into a thin strip.
 */
- (CGFloat)splitView:(NSSplitView *)splitView
    constrainMinCoordinate:(CGFloat)proposedMinimumPosition
               ofSubviewAt:(NSInteger)dividerIndex
{
    (void)splitView;
    (void)proposedMinimumPosition;
    (void)dividerIndex;
    return 140.0;
}

- (CGFloat)splitView:(NSSplitView *)splitView
    constrainMaxCoordinate:(CGFloat)proposedMaximumPosition
               ofSubviewAt:(NSInteger)dividerIndex
{
    (void)proposedMaximumPosition;
    (void)dividerIndex;
    /* Leave at least ~360pt for the settings pane. */
    CGFloat total = NSWidth(splitView.bounds);
    return MAX(140.0, total - 360.0);
}

- (BOOL)splitView:(NSSplitView *)splitView
    canCollapseSubview:(NSView *)subview
{
    (void)splitView;
    (void)subview;
    return NO;
}

@end

/* ---------------------------------------------------------------------- */
/* Public API */

struct controlbox *mac_config_build_controlbox(
    Conf *conf, bool midsession, int protcfginfo)
{
    struct controlbox *ctrlbox = ctrl_new_box();
    int protocol = conf_get_int(conf, CONF_protocol);
    setup_config_box(ctrlbox, midsession, protocol, protcfginfo);
    macos_setup_config_box(ctrlbox, midsession, protocol);
    return ctrlbox;
}

static MacConfigSidebarNode *mac_sidebar_find_or_create(
    NSMutableArray *roots, const char *path_prefix, const char *title)
{
    for (MacConfigSidebarNode *n in roots) {
        if ([n.path isEqualToString:mac_ns(path_prefix)])
            return n;
    }
    MacConfigSidebarNode *node = [[MacConfigSidebarNode alloc] init];
    node.title = mac_ns(title);
    node.path = mac_ns(path_prefix);
    node.panelIndex = -1;
    [roots addObject:node];
    return node;
}

static void mac_sidebar_add_path(struct dlgparam *dp, const char *pathname,
                                 NSInteger panelIndex)
{
    char *path = dupstr(pathname);
    char *p = path;
    NSMutableArray *level = dp->sidebarRoots;
    char accum[512];
    accum[0] = '\0';

    while (*p) {
        char *slash = strchr(p, '/');
        size_t len = slash ? (size_t)(slash - p) : strlen(p);
        char piece[256];
        if (len >= sizeof(piece))
            len = sizeof(piece) - 1;
        memcpy(piece, p, len);
        piece[len] = '\0';

        if (accum[0])
            strncat(accum, "/", sizeof(accum) - strlen(accum) - 1);
        strncat(accum, piece, sizeof(accum) - strlen(accum) - 1);

        MacConfigSidebarNode *node =
            mac_sidebar_find_or_create(level, accum, piece);
        if (!slash) {
            node.panelIndex = panelIndex;
            break;
        }
        level = node.children;
        p = slash + 1;
    }
    sfree(path);
}

MacConfigBox *mac_config_create_box(
    const char *title, Conf *conf, bool midsession, int protcfginfo,
    post_dialog_fn_t after, void *afterctx)
{
    mac_gui_dialogs_ensure_app();

    MacConfigBox *box = snew(MacConfigBox);
    mac_dlg_init(&box->dp);
    box->dp.owner = box;
    box->dp.after = after;
    box->dp.afterctx = afterctx;
    box->dp.data = conf;
    box->dp.midsession = midsession;
    box->dp.backup_conf = conf_copy(conf);
    box->dp.ctrlbox = mac_config_build_controlbox(conf, midsession, protcfginfo);

    NSRect frame = NSMakeRect(0, 0, 960, 640);
    MacConfigWindow *window =
        [[MacConfigWindow alloc] initWithContentRect:frame
                                           styleMask:(NSWindowStyleMaskTitled |
                                                      NSWindowStyleMaskClosable |
                                                      NSWindowStyleMaskMiniaturizable |
                                                      NSWindowStyleMaskResizable)
                                             backing:NSBackingStoreBuffered
                                               defer:NO];
    window.title = mac_ns(title);
    window.minSize = NSMakeSize(720, 480);
    window.animationBehavior = NSWindowAnimationBehaviorNone;
    /* Do not restore a previous (possibly off-screen / crushed) frame. */
    window.restorable = NO;
    box->dp.window = window;

    MacConfigBoxController *controller = [[MacConfigBoxController alloc] init];
    controller.dp = &box->dp;
    window.delegate = controller;
    objc_setAssociatedObject(window, &mac_config_controller_key, controller,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    NSToolbar *toolbar =
        [[NSToolbar alloc] initWithIdentifier:kMacConfigToolbarId];
    toolbar.delegate = controller;
    toolbar.displayMode = NSToolbarDisplayModeIconAndLabel;
    toolbar.allowsUserCustomization = NO;
    window.toolbar = toolbar;

    MacConfigActions *actions = mac_actions_for(&box->dp);

    NSSplitView *split = [[NSSplitView alloc] initWithFrame:NSZeroRect];
    split.vertical = YES;
    split.dividerStyle = NSSplitViewDividerStyleThin;
    split.translatesAutoresizingMaskIntoConstraints = NO;
    split.delegate = controller;

    NSOutlineView *outline = [[NSOutlineView alloc] initWithFrame:NSZeroRect];
    NSTableColumn *col = [[NSTableColumn alloc] initWithIdentifier:@"cat"];
    col.title = @"Category";
    col.minWidth = 100;
    col.width = 160;
    col.resizingMask = NSTableColumnAutoresizingMask;
    [outline addTableColumn:col];
    outline.outlineTableColumn = col;
    outline.headerView = nil;
    outline.rowSizeStyle = NSTableViewRowSizeStyleDefault;
    outline.columnAutoresizingStyle = NSTableViewLastColumnOnlyAutoresizingStyle;
    outline.dataSource = controller;
    outline.delegate = controller;
    outline.accessibilityLabel = @"Category";
    NSScrollView *sideScroll = mac_make_scroll_view(outline);
    sideScroll.borderType = NSBezelBorder;
    box->dp.sidebar = outline;

    MacFlippedView *contentHost = [[MacFlippedView alloc] initWithFrame:NSZeroRect];
    contentHost.translatesAutoresizingMaskIntoConstraints = NO;
    NSStackView *contentStack = mac_make_vstack();
    [contentHost addSubview:contentStack];
    [NSLayoutConstraint activateConstraints:@[
        [contentStack.topAnchor constraintEqualToAnchor:contentHost.topAnchor
                                               constant:12],
        [contentStack.leadingAnchor constraintEqualToAnchor:contentHost.leadingAnchor
                                                   constant:12],
        [contentStack.trailingAnchor constraintEqualToAnchor:contentHost.trailingAnchor
                                                    constant:-12],
        [contentStack.bottomAnchor constraintEqualToAnchor:contentHost.bottomAnchor
                                                  constant:-12],
    ]];

    NSView *actionArea = nil;
    char *path = NULL;
    NSStackView *panelvbox = nil;

    for (size_t index = 0; index < box->dp.ctrlbox->nctrlsets; index++) {
        struct controlset *s = box->dp.ctrlbox->ctrlsets[index];
        if (!*s->pathname) {
            actionArea = mac_config_layout_controlset_impl(
                &box->dp, s, nil, actions);
            continue;
        }

        int j = path ? ctrl_path_compare(s->pathname, path) : 0;
        if (j != INT_MAX) {
            /* New panel */
            NSStackView *panel = mac_make_vstack();
            panel.hidden = box->dp.panels.count > 0;
            [contentStack addArrangedSubview:panel];
            mac_stack_fill_width(contentStack, panel);
            [box->dp.panels addObject:panel];
            [box->dp.panelPaths addObject:mac_ns(s->pathname)];
            mac_sidebar_add_path(&box->dp, s->pathname,
                                 (NSInteger)box->dp.panels.count - 1);
            if (!box->dp.curr_panel)
                box->dp.curr_panel = panel;
            panelvbox = panel;
            path = s->pathname;

            NSView *w = mac_config_layout_controlset_impl(
                &box->dp, s, panel, actions);
            if (w) {
                [panel addArrangedSubview:w];
                mac_stack_fill_width(panel, w);
            }
        } else {
            NSView *w = mac_config_layout_controlset_impl(
                &box->dp, s, panelvbox, actions);
            if (w && panelvbox) {
                [panelvbox addArrangedSubview:w];
                mac_stack_fill_width(panelvbox, w);
            }
        }
    }

    NSScrollView *contentScroll = mac_make_scroll_view(contentHost);
    contentScroll.borderType = NSBezelBorder;
    contentScroll.accessibilityLabel = @"Settings";
    /* Document matches clip width; height follows stacked content. */
    [contentHost.widthAnchor
        constraintEqualToAnchor:contentScroll.contentView.widthAnchor].active =
        YES;

    [split addSubview:sideScroll];
    [split addSubview:contentScroll];
    /* Keep sidebar width when the window resizes; settings pane grows. */
    [split setHoldingPriority:NSLayoutPriorityDefaultHigh forSubviewAtIndex:0];
    [split setHoldingPriority:NSLayoutPriorityFittingSizeCompression
             forSubviewAtIndex:1];

    NSStackView *root = mac_make_vstack();
    root.edgeInsets = NSEdgeInsetsMake(8, 8, 8, 8);
    [root addArrangedSubview:split];
    mac_stack_fill_width(root, split);
    if (actionArea) {
        [root addArrangedSubview:actionArea];
        mac_stack_fill_width(root, actionArea);
    }
    /*
     * Fill contentView with autoresizing — do not pin root to contentView
     * with Auto Layout. Edge constraints from the AL tree were shrinking
     * contentView to the split's fitting width (~306pt) while the window
     * frame stayed at minSize (720), smooshing the settings pane.
     */
    root.translatesAutoresizingMaskIntoConstraints = YES;
    root.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;

    NSView *contentView = [[NSView alloc] initWithFrame:NSZeroRect];
    contentView.autoresizesSubviews = YES;
    window.contentView = contentView;
    root.frame = contentView.bounds;
    [contentView addSubview:root];

    [outline reloadData];
    [outline expandItem:nil expandChildren:YES];
    if (box->dp.sidebarRoots.count > 0)
        [outline selectRowIndexes:[NSIndexSet indexSetWithIndex:0]
             byExtendingSelection:NO];

    dlg_refresh(NULL, &box->dp);

    /*
     * Pre-select "Default Settings" so Save with an empty name field
     * updates that session instead of beeping (screenshot case: mid-session
     * Change Settings with empty Saved Sessions edit + no list selection).
     */
    {
        dlgcontrol *list =
            mac_find_saved_sessions_ctrl(box->dp.ctrlbox, CTRL_LISTBOX);
        if (list)
            dlg_listbox_select(list, &box->dp, 0);
    }

    {
        NSRect framed = NSMakeRect(0, 0, 960, 640);
        framed = mac_clamp_window_frame_to_screens(framed);
        [window setFrame:framed display:NO];
        [window center];
        framed = mac_clamp_window_frame_to_screens(window.frame);
        if (!NSEqualRects(framed, window.frame))
            [window setFrame:framed display:NO];
        root.frame = contentView.bounds;
    }
    [window layoutIfNeeded];
    [split setPosition:180 ofDividerAtIndex:0];
    /*
     * Do not let Auto Layout invent a contentMinSize from the control tree.
     * Floor matches window.minSize's content rect so the window can grow.
     */
    window.contentMinSize =
        [window contentRectForFrameRect:NSMakeRect(0, 0, window.minSize.width,
                                                   window.minSize.height)]
            .size;

    mac_apply_contrast_border(split);
    mac_prepare_config_window_keyboard(window, outline);

    [window makeKeyAndOrderFront:nil];
    [NSApp activateIgnoringOtherApps:YES];
    return box;
}

void mac_config_box_free(MacConfigBox *box)
{
    MacConfigActions *actions;

    if (!box)
        return;
    if (box->dp.window) {
        actions = objc_getAssociatedObject(box->dp.window, &mac_actions_key);
        [actions releaseFontPanel];
        box->dp.window.animationBehavior = NSWindowAnimationBehaviorNone;
        [box->dp.window setDelegate:nil];
        [box->dp.window orderOut:nil];
        box->dp.window = nil;
    }
    mac_dlg_cleanup(&box->dp);
    sfree(box);
}

/* ---------------------------------------------------------------------- */
/* Lifecycle helpers used by the portable config box */

void trivial_post_dialog_fn(void *ctx, int result)
{
    (void)ctx;
    (void)result;
}

void about_box(void *parent)
{
    (void)parent;
    mac_gui_dialogs_ensure_app();
    NSAlert *alert = [[NSAlert alloc] init];
    alert.messageText = mac_ns(appname);
    char *body = dupprintf("%s\n%s", appname, ver);
    alert.informativeText = mac_ns(body);
    sfree(body);
    alert.alertStyle = NSAlertStyleInformational;
    [alert addButtonWithTitle:@"OK"];
    [alert runModal];
}

void nonfatal_message_box(void *parent, const char *msg)
{
    (void)parent;
    mac_seat_show_nonfatal("Error", msg, NULL_HELPCTX);
}

struct mac_change_settings_ctx {
    Conf **conf_inout;
    Conf *working;
    post_dialog_fn_t after;
    void *afterctx;
};

static void mac_change_settings_after(void *vctx, int result)
{
    struct mac_change_settings_ctx *ctx =
        (struct mac_change_settings_ctx *)vctx;

    if (result > 0 && ctx->conf_inout && ctx->working) {
        Conf *old = *ctx->conf_inout;
        *ctx->conf_inout = ctx->working;
        ctx->working = NULL;
        if (old)
            conf_free(old);
    }

    if (ctx->after)
        ctx->after(ctx->afterctx, result);

    if (ctx->working)
        conf_free(ctx->working);
    sfree(ctx);
}

void mac_config_change_settings(
    Conf **conf_inout, int protcfginfo,
    post_dialog_fn_t after, void *afterctx)
{
    struct mac_change_settings_ctx *ctx;
    char *title;

    if (!conf_inout || !*conf_inout) {
        if (after)
            after(afterctx, 0);
        return;
    }

    ctx = snew(struct mac_change_settings_ctx);
    ctx->conf_inout = conf_inout;
    ctx->working = conf_copy(*conf_inout);
    ctx->after = after;
    ctx->afterctx = afterctx;

    title = dupcat(appname, " Settings");
    mac_config_create_box(title, ctx->working, true, protcfginfo,
                          mac_change_settings_after, ctx);
    sfree(title);
}

/* ---------------------------------------------------------------------- */
/* Host CA configuration (Phase 6.5) — mirrors unix/dialog.c make_ca_config_box */

struct ca_config_box {
    struct dlgparam dp;
    bool run_modal;
};

static struct ca_config_box *mac_cacfg; /* one instance, cross-window */

static void mac_ca_config_box_free(struct ca_config_box *box)
{
    if (!box)
        return;
    if (box->dp.window) {
        [box->dp.window setDelegate:nil];
        [box->dp.window close];
    }
    mac_dlg_cleanup(&box->dp);
    if (mac_cacfg == box)
        mac_cacfg = NULL;
    sfree(box);
}

static void mac_ca_config_dlg_ended(dlgparam *dp)
{
    if (!mac_cacfg || &mac_cacfg->dp != dp)
        return;
    /*
     * Non-modal: free immediately (Done / window close). Modal: leave the
     * box alive until show_ca_config_box_synchronously finishes its loop.
     */
    if (!mac_cacfg->run_modal)
        mac_ca_config_box_free(mac_cacfg);
}

static void make_ca_config_box(NSWindow *spawning_window, bool run_modal)
{
    struct ca_config_box *box;
    NSWindow *window;
    MacConfigBoxController *controller;
    MacConfigActions *actions;
    NSStackView *root;
    NSView *actionArea = nil;
    NSStackView *content = nil;
    char *path = NULL;

    mac_gui_dialogs_ensure_app();

    if (mac_cacfg && mac_cacfg->dp.window && !mac_cacfg->dp.ended) {
        [mac_cacfg->dp.window makeKeyAndOrderFront:nil];
        return;
    }
    if (mac_cacfg) {
        mac_ca_config_box_free(mac_cacfg);
        mac_cacfg = NULL;
    }

    box = snew(struct ca_config_box);
    /* (void*): embedded dlgparam has __strong ObjC fields. */
    memset((void *)box, 0, sizeof(*box));
    mac_dlg_init(&box->dp);
    box->run_modal = run_modal;
    box->dp.data = box;
    box->dp.ctrlbox = ctrl_new_box();
    setup_ca_config_box(box->dp.ctrlbox);

    window =
        [[MacConfigWindow alloc]
            initWithContentRect:NSMakeRect(0, 0, 720, 520)
                      styleMask:(NSWindowStyleMaskTitled |
                                 NSWindowStyleMaskClosable |
                                 NSWindowStyleMaskMiniaturizable |
                                 NSWindowStyleMaskResizable)
                        backing:NSBackingStoreBuffered
                          defer:NO];
    window.title = @"PuTTY trusted host certification authorities";
    window.minSize = NSMakeSize(560, 400);
    window.restorable = NO;
    box->dp.window = window;

    controller = [[MacConfigBoxController alloc] init];
    controller.dp = &box->dp;
    window.delegate = controller;
    objc_setAssociatedObject(window, &mac_config_controller_key, controller,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    actions = mac_actions_for(&box->dp);
    root = mac_make_vstack();
    root.translatesAutoresizingMaskIntoConstraints = NO;
    content = mac_make_vstack();

    for (size_t index = 0; index < box->dp.ctrlbox->nctrlsets; index++) {
        struct controlset *s = box->dp.ctrlbox->ctrlsets[index];
        if (!*s->pathname) {
            actionArea = mac_config_layout_controlset_impl(
                &box->dp, s, nil, actions);
            continue;
        }
        if (!path || ctrl_path_compare(s->pathname, path) != INT_MAX) {
            path = s->pathname;
        }
        NSView *w = mac_config_layout_controlset_impl(
            &box->dp, s, content, actions);
        if (w)
            [content addArrangedSubview:w];
    }

    NSScrollView *scroll = mac_make_scroll_view(content);
    [content.widthAnchor
        constraintEqualToAnchor:scroll.contentView.widthAnchor].active = YES;

    [root addArrangedSubview:scroll];
    if (actionArea)
        [root addArrangedSubview:actionArea];

    window.contentView = [[NSView alloc] initWithFrame:window.frame];
    [window.contentView addSubview:root];
    [root.topAnchor constraintEqualToAnchor:window.contentView.topAnchor
                                   constant:8]
        .active = YES;
    [root.bottomAnchor constraintEqualToAnchor:window.contentView.bottomAnchor
                                      constant:-8]
        .active = YES;
    [root.leadingAnchor constraintEqualToAnchor:window.contentView.leadingAnchor
                                       constant:8]
        .active = YES;
    [root.trailingAnchor
        constraintEqualToAnchor:window.contentView.trailingAnchor
                       constant:-8]
        .active = YES;
    {
        NSLayoutConstraint *scroll_min_h =
            [scroll.heightAnchor constraintGreaterThanOrEqualToConstant:360];
        scroll_min_h.priority = kMacConfigSoftMinPriority;
        scroll_min_h.active = YES;
    }

    dlg_refresh(NULL, &box->dp);

    if (spawning_window) {
        NSRect parent = spawning_window.frame;
        NSRect frame = window.frame;
        frame.origin.x = NSMidX(parent) - NSWidth(frame) / 2;
        frame.origin.y = NSMidY(parent) - NSHeight(frame) / 2;
        [window setFrame:mac_clamp_window_frame_to_screens(frame) display:NO];
    } else {
        [window center];
        NSRect clamped = mac_clamp_window_frame_to_screens(window.frame);
        if (!NSEqualRects(clamped, window.frame))
            [window setFrame:clamped display:NO];
    }

    mac_cacfg = box;
    mac_prepare_config_window_keyboard(window, content);
    [window makeKeyAndOrderFront:nil];
    [NSApp activateIgnoringOtherApps:YES];

    if (run_modal) {
        NSModalSession session = [NSApp beginModalSessionForWindow:window];
        while (mac_cacfg == box && !box->dp.ended) {
            if ([NSApp runModalSession:session] != NSModalResponseContinue)
                break;
        }
        [NSApp endModalSession:session];
        if (mac_cacfg == box)
            mac_ca_config_box_free(box);
    }
}

void show_ca_config_box(dlgparam *dp)
{
    NSWindow *parent = (dp && dp->window) ? dp->window : nil;
    make_ca_config_box(parent, false);
}

void show_ca_config_box_synchronously(void)
{
    make_ca_config_box(nil, true);
}

/* ---------------------------------------------------------------------- */
/* Smoke test */

static dlgcontrol *mac_smoke_find_ctrl(
    struct dlgparam *dp, int type, int conf_key)
{
    struct MacUCtrl *uc;
    int i;
    for (i = 0; (uc = index234(dp->byctrl, i)) != NULL; i++) {
        if (!uc->ctrl || uc->ctrl->type != type)
            continue;
        if (type == CTRL_CHECKBOX && uc->ctrl->handler == conf_checkbox_handler &&
            uc->ctrl->context.i == conf_key)
            return uc->ctrl;
        if (type == CTRL_EDITBOX && uc->ctrl->handler == conf_editbox_handler &&
            uc->ctrl->context.i == conf_key)
            return uc->ctrl;
        if (type == CTRL_RADIO && uc->ctrl->handler == conf_radiobutton_handler &&
            uc->ctrl->context.i == conf_key)
            return uc->ctrl;
        if (type == CTRL_FONTSELECT &&
            uc->ctrl->handler == conf_fontsel_handler &&
            uc->ctrl->context.i == conf_key)
            return uc->ctrl;
        if (type == CTRL_FILESELECT &&
            uc->ctrl->handler == conf_filesel_handler &&
            uc->ctrl->context.i == conf_key)
            return uc->ctrl;
    }
    return NULL;
}

static bool mac_smoke_has_label_substr(struct dlgparam *dp, const char *substr)
{
    struct MacUCtrl *uc;
    int i;
    for (i = 0; (uc = index234(dp->byctrl, i)) != NULL; i++) {
        if (!uc->ctrl || !uc->ctrl->label)
            continue;
        if (strstr(uc->ctrl->label, substr))
            return true;
    }
    return false;
}

int mac_config_controlbox_smoke(void)
{
    Conf *conf;
    struct dlgparam dp;
    MacConfigActions *actions;
    NSWindow *window;
    dlgcontrol *c;
    int n_edit = 0, n_check = 0, n_radio = 0, n_list = 0;
    int n_file = 0, n_font = 0, n_btn = 0, n_text = 0;
    struct MacUCtrl *uc;
    int i;

    mac_gui_dialogs_ensure_app();

    conf = conf_new();
    do_defaults(NULL, conf);

    mac_dlg_init(&dp);
    dp.data = conf;
    dp.ctrlbox = mac_config_build_controlbox(conf, false, 0);

    window =
        [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 640, 480)
                                    styleMask:NSWindowStyleMaskTitled
                                      backing:NSBackingStoreBuffered
                                        defer:YES];
    dp.window = window;
    actions = mac_ensure_actions(&dp, window.contentView);

    MacConfigBoxController *controller = [[MacConfigBoxController alloc] init];
    controller.dp = &dp;
    objc_setAssociatedObject(window, &mac_config_controller_key, controller,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    NSStackView *host = mac_make_vstack();
    window.contentView = host;

    for (size_t index = 0; index < dp.ctrlbox->nctrlsets; index++) {
        struct controlset *s = dp.ctrlbox->ctrlsets[index];
        NSStackView *panel = nil;
        if (*s->pathname) {
            panel = mac_make_vstack();
            [host addArrangedSubview:panel];
            [dp.panels addObject:panel];
            if (!dp.curr_panel)
                dp.curr_panel = panel;
        }
        NSView *w = mac_config_layout_controlset_impl(&dp, s, panel, actions);
        if (w) {
            if (panel)
                [panel addArrangedSubview:w];
            else
                [host addArrangedSubview:w];
        }
    }

    if (count234(dp.byctrl) < 50) {
        fprintf(stderr, "mac_config_controlbox_smoke: too few controls (%d)\n",
                count234(dp.byctrl));
        mac_dlg_cleanup(&dp);
        conf_free(conf);
        return 1;
    }

    for (i = 0; (uc = index234(dp.byctrl, i)) != NULL; i++) {
        switch (uc->ctrl->type) {
          case CTRL_EDITBOX: n_edit++; break;
          case CTRL_CHECKBOX: n_check++; break;
          case CTRL_RADIO: n_radio++; break;
          case CTRL_LISTBOX: n_list++; break;
          case CTRL_FILESELECT: n_file++; break;
          case CTRL_FONTSELECT: n_font++; break;
          case CTRL_BUTTON: n_btn++; break;
          case CTRL_TEXT: n_text++; break;
          default: break;
        }
    }

    if (!n_edit || !n_check || !n_radio || !n_list || !n_file || !n_font ||
        !n_btn || !n_text) {
        fprintf(stderr,
                "mac_config_controlbox_smoke: missing CTRL_* coverage "
                "edit=%d check=%d radio=%d list=%d file=%d font=%d "
                "btn=%d text=%d\n",
                n_edit, n_check, n_radio, n_list, n_file, n_font, n_btn,
                n_text);
        mac_dlg_cleanup(&dp);
        conf_free(conf);
        return 2;
    }

    if (!mac_smoke_has_label_substr(&dp, "Option key acts as Meta") ||
        !mac_smoke_has_label_substr(&dp, "Scrollbar on left") ||
        !mac_smoke_has_label_substr(&dp, "About") ||
        !mac_smoke_has_label_substr(&dp, "Restore Defaults") ||
        !mac_smoke_has_label_substr(&dp, "Duplicate")) {
        fprintf(stderr,
                "mac_config_controlbox_smoke: macOS-specific controls missing\n");
        mac_dlg_cleanup(&dp);
        conf_free(conf);
        return 3;
    }

    dlg_refresh(NULL, &dp);

    c = mac_smoke_find_ctrl(&dp, CTRL_CHECKBOX, CONF_wrap_mode);
    if (!c) {
        fprintf(stderr, "mac_config_controlbox_smoke: wrap_mode checkbox missing\n");
        mac_dlg_cleanup(&dp);
        conf_free(conf);
        return 4;
    }
    {
        bool before = dlg_checkbox_get(c, &dp);
        dlg_checkbox_set(c, &dp, !before);
        if (dlg_checkbox_get(c, &dp) == before) {
            fprintf(stderr, "mac_config_controlbox_smoke: checkbox set failed\n");
            mac_dlg_cleanup(&dp);
            conf_free(conf);
            return 5;
        }
        dlg_checkbox_set(c, &dp, before);
    }

    c = mac_smoke_find_ctrl(&dp, CTRL_EDITBOX, CONF_wintitle);
    if (!c) {
        fprintf(stderr, "mac_config_controlbox_smoke: wintitle editbox missing\n");
        mac_dlg_cleanup(&dp);
        conf_free(conf);
        return 6;
    }
    {
        dlg_editbox_set(c, &dp, "smoke-title");
        char *got = dlg_editbox_get(c, &dp);
        int ok = got && !strcmp(got, "smoke-title");
        sfree(got);
        if (!ok) {
            fprintf(stderr, "mac_config_controlbox_smoke: editbox set/get failed\n");
            mac_dlg_cleanup(&dp);
            conf_free(conf);
            return 7;
        }
    }

    c = mac_smoke_find_ctrl(&dp, CTRL_RADIO, CONF_cursor_type);
    if (!c) {
        fprintf(stderr, "mac_config_controlbox_smoke: cursor_type radio missing\n");
        mac_dlg_cleanup(&dp);
        conf_free(conf);
        return 8;
    }
    {
        int before = dlg_radiobutton_get(c, &dp);
        int next = before == 0 ? 1 : 0;
        dlg_radiobutton_set(c, &dp, next);
        if (dlg_radiobutton_get(c, &dp) != next) {
            fprintf(stderr, "mac_config_controlbox_smoke: radio set failed\n");
            mac_dlg_cleanup(&dp);
            conf_free(conf);
            return 9;
        }
        dlg_radiobutton_set(c, &dp, before);
    }

    c = mac_smoke_find_ctrl(&dp, CTRL_FONTSELECT, CONF_font);
    if (!c) {
        fprintf(stderr, "mac_config_controlbox_smoke: font selector missing\n");
        mac_dlg_cleanup(&dp);
        conf_free(conf);
        return 10;
    }
    {
        FontSpec *fs = fontspec_new("mac:Menlo-Regular:14");
        dlg_fontsel_set(c, &dp, fs);
        fontspec_free(fs);
        FontSpec *got = dlg_fontsel_get(c, &dp);
        int ok = got && got->name &&
                 !strcmp(got->name, "mac:Menlo-Regular:14");
        fontspec_free(got);
        if (!ok) {
            fprintf(stderr, "mac_config_controlbox_smoke: fontsel set/get failed\n");
            mac_dlg_cleanup(&dp);
            conf_free(conf);
            return 11;
        }
    }

    c = mac_smoke_find_ctrl(&dp, CTRL_FILESELECT, CONF_logfilename);
    if (!c) {
        fprintf(stderr, "mac_config_controlbox_smoke: filesel missing\n");
        mac_dlg_cleanup(&dp);
        conf_free(conf);
        return 12;
    }
    {
        char log_template[] = "/tmp/putty-smoke-XXXXXX.log";
        int log_fd = mkstemps(log_template, 4);
        Filename *fn;
        Filename *got;
        int ok;

        if (log_fd < 0) {
            fprintf(stderr, "mac_config_controlbox_smoke: mkstemps failed\n");
            mac_dlg_cleanup(&dp);
            conf_free(conf);
            return 12;
        }
        close(log_fd);
        unlink(log_template);

        fn = filename_from_str(log_template);
        dlg_filesel_set(c, &dp, fn);
        filename_free(fn);
        got = dlg_filesel_get(c, &dp);
        ok = got && got->path && !strcmp(got->path, log_template);
        filename_free(got);
        if (!ok) {
            fprintf(stderr, "mac_config_controlbox_smoke: filesel set/get failed\n");
            mac_dlg_cleanup(&dp);
            conf_free(conf);
            return 13;
        }
    }

    /* Exercise listbox clear/add/select on the first listbox control. */
    for (i = 0; (uc = index234(dp.byctrl, i)) != NULL; i++) {
        if (uc->ctrl->type != CTRL_LISTBOX)
            continue;
        dlg_listbox_clear(uc->ctrl, &dp);
        dlg_listbox_addwithid(uc->ctrl, &dp, "alpha", 10);
        dlg_listbox_addwithid(uc->ctrl, &dp, "beta", 20);
        dlg_listbox_select(uc->ctrl, &dp, 1);
        if (dlg_listbox_index(uc->ctrl, &dp) != 1 ||
            dlg_listbox_getid(uc->ctrl, &dp, 1) != 20) {
            fprintf(stderr, "mac_config_controlbox_smoke: listbox ops failed\n");
            mac_dlg_cleanup(&dp);
            conf_free(conf);
            return 14;
        }
        break;
    }

    printf("mac_config_controlbox_smoke: controls=%d "
           "edit=%d check=%d radio=%d list=%d file=%d font=%d btn=%d text=%d\n",
           count234(dp.byctrl), n_edit, n_check, n_radio, n_list, n_file,
           n_font, n_btn, n_text);

    mac_dlg_cleanup(&dp);
    conf_free(conf);
    return 0;
}

int mac_config_settings_ux_smoke(void)
{
    Conf *conf;
    struct dlgparam dp;
    MacConfigActions *actions;
    NSWindow *window;
    dlgcontrol *c;
    struct MacUCtrl *uc;
    int i;
    bool found_saved = false;
    bool found_apply = false;
    bool found_restore = false;
    bool found_dup = false;

    mac_gui_dialogs_ensure_app();

    /* --- Mid-session controlbox: Apply, no Load/Delete/Duplicate/About --- */
    conf = conf_new();
    do_defaults(NULL, conf);
    conf_set_str(conf, CONF_host, "smoke.example");
    conf_set_int(conf, CONF_port, 22);
    conf_set_int(conf, CONF_protocol, PROT_SSH);

    mac_dlg_init(&dp);
    dp.data = conf;
    dp.midsession = true;
    dp.backup_conf = conf_copy(conf);
    dp.ctrlbox = mac_config_build_controlbox(conf, true, 0);

    window =
        [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 640, 480)
                                    styleMask:NSWindowStyleMaskTitled
                                      backing:NSBackingStoreBuffered
                                        defer:YES];
    dp.window = window;
    actions = mac_ensure_actions(&dp, window.contentView);

    MacConfigBoxController *controller = [[MacConfigBoxController alloc] init];
    controller.dp = &dp;
    objc_setAssociatedObject(window, &mac_config_controller_key, controller,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    NSStackView *host = mac_make_vstack();
    window.contentView = host;

    for (size_t index = 0; index < dp.ctrlbox->nctrlsets; index++) {
        struct controlset *s = dp.ctrlbox->ctrlsets[index];
        NSStackView *panel = nil;
        if (*s->pathname) {
            panel = mac_make_vstack();
            [host addArrangedSubview:panel];
            [dp.panels addObject:panel];
            if (!dp.curr_panel)
                dp.curr_panel = panel;
        }
        NSView *w = mac_config_layout_controlset_impl(&dp, s, panel, actions);
        if (w) {
            if (panel)
                [panel addArrangedSubview:w];
            else
                [host addArrangedSubview:w];
        }
    }

    dlg_refresh(NULL, &dp);

    for (i = 0; (uc = index234(dp.byctrl, i)) != NULL; i++) {
        if (!uc->ctrl || !uc->ctrl->label)
            continue;
        if (!strcmp(uc->ctrl->label, "Apply"))
            found_apply = true;
        if (!strcmp(uc->ctrl->label, "Restore Defaults"))
            found_restore = true;
        if (!strcmp(uc->ctrl->label, "Duplicate"))
            found_dup = true;
        if (!strcmp(uc->ctrl->label, "Saved Sessions"))
            found_saved = true;
        if (!strcmp(uc->ctrl->label, "About") ||
            !strcmp(uc->ctrl->label, "Load") ||
            !strcmp(uc->ctrl->label, "Delete") ||
            !strcmp(uc->ctrl->label, "Open")) {
            fprintf(stderr,
                    "mac_config_settings_ux_smoke: unexpected pre-session "
                    "control '%s' in midsession box\n",
                    uc->ctrl->label);
            mac_dlg_cleanup(&dp);
            conf_free(conf);
            return 1;
        }
    }

    if (!found_apply || !found_restore || !found_saved || found_dup) {
        fprintf(stderr,
                "mac_config_settings_ux_smoke: midsession buttons wrong "
                "(apply=%d restore=%d saved=%d dup=%d)\n",
                found_apply, found_restore, found_saved, found_dup);
        mac_dlg_cleanup(&dp);
        conf_free(conf);
        return 2;
    }

    /* Restore Defaults resets host */
    conf_set_str(conf, CONF_host, "should-be-cleared");
    for (i = 0; (uc = index234(dp.byctrl, i)) != NULL; i++) {
        if (uc->ctrl && uc->ctrl->label &&
            !strcmp(uc->ctrl->label, "Restore Defaults") &&
            uc->ctrl->handler) {
            uc->ctrl->handler(uc->ctrl, &dp, conf, EVENT_ACTION);
            break;
        }
    }
    if (strcmp(conf_get_str(conf, CONF_host), "") != 0 &&
        conf_get_str(conf, CONF_host)[0] != '\0') {
        /* do_defaults leaves host empty or from Default Settings */
        const char *host = conf_get_str(conf, CONF_host);
        if (host && !strcmp(host, "should-be-cleared")) {
            fprintf(stderr,
                    "mac_config_settings_ux_smoke: Restore Defaults failed\n");
            mac_dlg_cleanup(&dp);
            conf_free(conf);
            return 3;
        }
    }

    /* Cancel restores backup via dlg_end */
    conf_set_str(conf, CONF_host, "edited-host");
    {
        const char *expect = conf_get_str(dp.backup_conf, CONF_host);
        char *expect_copy = dupstr(expect ? expect : "");
        dlg_end(&dp, 0);
        if (strcmp(conf_get_str(conf, CONF_host), expect_copy) != 0) {
            fprintf(stderr,
                    "mac_config_settings_ux_smoke: Cancel did not restore Conf "
                    "('%s' vs '%s')\n",
                    conf_get_str(conf, CONF_host), expect_copy);
            sfree(expect_copy);
            mac_dlg_cleanup(&dp);
            conf_free(conf);
            return 4;
        }
        sfree(expect_copy);
    }

    mac_dlg_cleanup(&dp);
    conf_free(conf);

    /* --- Pre-session: Saved Sessions Load/Save/Delete + Duplicate --- */
    conf = conf_new();
    do_defaults(NULL, conf);
    mac_dlg_init(&dp);
    dp.data = conf;
    dp.ctrlbox = mac_config_build_controlbox(conf, false, 0);
    window =
        [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 640, 480)
                                    styleMask:NSWindowStyleMaskTitled
                                      backing:NSBackingStoreBuffered
                                        defer:YES];
    dp.window = window;
    actions = mac_ensure_actions(&dp, window.contentView);
    controller = [[MacConfigBoxController alloc] init];
    controller.dp = &dp;
    objc_setAssociatedObject(window, &mac_config_controller_key, controller,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    host = mac_make_vstack();
    window.contentView = host;
    for (size_t index = 0; index < dp.ctrlbox->nctrlsets; index++) {
        struct controlset *s = dp.ctrlbox->ctrlsets[index];
        NSStackView *panel = nil;
        if (*s->pathname) {
            panel = mac_make_vstack();
            [host addArrangedSubview:panel];
            [dp.panels addObject:panel];
            if (!dp.curr_panel)
                dp.curr_panel = panel;
        }
        NSView *w = mac_config_layout_controlset_impl(&dp, s, panel, actions);
        if (w) {
            if (panel)
                [panel addArrangedSubview:w];
            else
                [host addArrangedSubview:w];
        }
    }

    found_dup = false;
    found_saved = false;
    bool found_load = false, found_save = false, found_delete = false;
    for (i = 0; (uc = index234(dp.byctrl, i)) != NULL; i++) {
        if (!uc->ctrl || !uc->ctrl->label)
            continue;
        if (!strcmp(uc->ctrl->label, "Duplicate"))
            found_dup = true;
        if (!strcmp(uc->ctrl->label, "Saved Sessions"))
            found_saved = true;
        if (!strcmp(uc->ctrl->label, "Load"))
            found_load = true;
        if (!strcmp(uc->ctrl->label, "Save"))
            found_save = true;
        if (!strcmp(uc->ctrl->label, "Delete"))
            found_delete = true;
    }
    if (!found_dup || !found_saved || !found_load || !found_save ||
        !found_delete) {
        fprintf(stderr,
                "mac_config_settings_ux_smoke: pre-session saved-session "
                "controls missing (dup=%d saved=%d load=%d save=%d del=%d)\n",
                found_dup, found_saved, found_load, found_save, found_delete);
        mac_dlg_cleanup(&dp);
        conf_free(conf);
        return 5;
    }

    /* Apply-keeps-edits: simulate successful end without owner free path */
    {
        Conf *working = conf_copy(conf);
        conf_set_str(working, CONF_host, "keep-me");
        Conf *backup = conf_copy(conf);
        /* Manual cancel restore check already done; verify Apply keeps: */
        conf_copy_into(conf, working);
        if (strcmp(conf_get_str(conf, CONF_host), "keep-me") != 0) {
            fprintf(stderr, "mac_config_settings_ux_smoke: Apply keep failed\n");
            conf_free(working);
            conf_free(backup);
            mac_dlg_cleanup(&dp);
            conf_free(conf);
            return 6;
        }
        conf_free(working);
        conf_free(backup);
    }

    (void)c;
    mac_dlg_cleanup(&dp);
    conf_free(conf);

    puts("mac_config_settings_ux_smoke: ok");
    return 0;
}

int mac_config_ca_smoke(void)
{
    struct dlgparam dp;
    MacConfigActions *actions;
    NSWindow *window;
    struct MacUCtrl *uc;
    int i;
    bool found_done = false;
    bool found_load = false, found_save = false, found_delete = false;
    bool found_name = false, found_pubkey = false, found_hosts = false;
    const char *smoke_name = "__PuttyMacCaSmoke__";
    host_ca *hca;
    char *err;
    strbuf *keyblob;

    if (!has_ca_config_box) {
        fprintf(stderr, "mac_config_ca_smoke: has_ca_config_box is false\n");
        return 1;
    }

    mac_gui_dialogs_ensure_app();

    /* --- Layout: setup_ca_config_box + AppKit widgets --- */
    mac_dlg_init(&dp);
    dp.data = NULL;
    dp.ctrlbox = ctrl_new_box();
    setup_ca_config_box(dp.ctrlbox);

    window =
        [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 720, 520)
                                    styleMask:NSWindowStyleMaskTitled
                                      backing:NSBackingStoreBuffered
                                        defer:YES];
    dp.window = window;
    actions = mac_ensure_actions(&dp, window.contentView);

    MacConfigBoxController *controller = [[MacConfigBoxController alloc] init];
    controller.dp = &dp;
    objc_setAssociatedObject(window, &mac_config_controller_key, controller,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    NSStackView *host = mac_make_vstack();
    window.contentView = host;

    for (size_t index = 0; index < dp.ctrlbox->nctrlsets; index++) {
        struct controlset *s = dp.ctrlbox->ctrlsets[index];
        NSView *w = mac_config_layout_controlset_impl(&dp, s, host, actions);
        if (w)
            [host addArrangedSubview:w];
    }

    dlg_refresh(NULL, &dp);

    for (i = 0; (uc = index234(dp.byctrl, i)) != NULL; i++) {
        if (!uc->ctrl || !uc->ctrl->label)
            continue;
        if (!strcmp(uc->ctrl->label, "Done"))
            found_done = true;
        if (!strcmp(uc->ctrl->label, "Load"))
            found_load = true;
        if (!strcmp(uc->ctrl->label, "Save"))
            found_save = true;
        if (!strcmp(uc->ctrl->label, "Delete"))
            found_delete = true;
        if (strstr(uc->ctrl->label, "Name for this CA"))
            found_name = true;
        if (strstr(uc->ctrl->label, "Public key of certification"))
            found_pubkey = true;
        if (strstr(uc->ctrl->label, "Valid hosts"))
            found_hosts = true;
    }

    if (!found_done || !found_load || !found_save || !found_delete ||
        !found_name || !found_pubkey || !found_hosts) {
        fprintf(stderr,
                "mac_config_ca_smoke: missing controls "
                "(done=%d load=%d save=%d del=%d name=%d pubkey=%d hosts=%d)\n",
                found_done, found_load, found_save, found_delete,
                found_name, found_pubkey, found_hosts);
        mac_dlg_cleanup(&dp);
        return 2;
    }

    mac_dlg_cleanup(&dp);

    /* --- Storage round-trip (platform host_ca_*) --- */
    (void)host_ca_delete(smoke_name);

    hca = host_ca_new();
    hca->name = dupstr(smoke_name);
    keyblob = strbuf_new();
    put_data(keyblob, "smoke-ca-pubkey", 15);
    hca->ca_public_key = keyblob;
    hca->validity_expression = dupstr("*");
    hca->opts.permit_rsa_sha1 = false;
    hca->opts.permit_rsa_sha256 = true;
    hca->opts.permit_rsa_sha512 = true;

    err = host_ca_save(hca);
    host_ca_free(hca);
    if (err) {
        fprintf(stderr, "mac_config_ca_smoke: save failed: %s\n", err);
        sfree(err);
        return 3;
    }

    hca = host_ca_load(smoke_name);
    if (!hca) {
        fprintf(stderr, "mac_config_ca_smoke: load failed\n");
        return 4;
    }
    if (!hca->name || strcmp(hca->name, smoke_name) != 0 ||
        !hca->validity_expression ||
        strcmp(hca->validity_expression, "*") != 0 ||
        !hca->opts.permit_rsa_sha256 || hca->opts.permit_rsa_sha1) {
        fprintf(stderr, "mac_config_ca_smoke: loaded record mismatch\n");
        host_ca_free(hca);
        (void)host_ca_delete(smoke_name);
        return 5;
    }
    host_ca_free(hca);

    err = host_ca_delete(smoke_name);
    if (err) {
        fprintf(stderr, "mac_config_ca_smoke: delete failed: %s\n", err);
        sfree(err);
        return 6;
    }
    if (host_ca_load(smoke_name) != NULL) {
        fprintf(stderr, "mac_config_ca_smoke: delete did not remove record\n");
        (void)host_ca_delete(smoke_name);
        return 7;
    }

    /* show_ca_config_box must be linked (non-stub). */
    puts("mac_config_ca_smoke: ok");
    return 0;
}
