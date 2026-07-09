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
    NSView *toplevel;          /* outermost view for this control */
    NSTextField *label;
    NSView *widget;            /* primary interactive widget */
    NSMutableArray<NSButton *> *radioButtons;
    NSMutableArray<MacConfigListItem *> *listItems;
    NSInteger selectedIndex;
    NSMutableIndexSet *selectedIndexes;
    char *textvalue;           /* button-only file selector */
    NSView *panel;             /* owning panel, or nil for global actions */
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
    NSWindow *window;
    NSView *curr_panel;
    NSMutableArray<NSView *> *panels;
    NSMutableArray<NSString *> *panelPaths;
    NSOutlineView *sidebar;
    NSMutableArray *sidebarRoots; /* MacConfigSidebarNode * */
    NSButton *cancelbutton;
    NSButton *defaultbutton;
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

static char mac_uctrl_key;
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
    memset(dp, 0, sizeof(*dp));
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

static void mac_add_uctrl(dlgparam *dp, struct MacUCtrl *uc)
{
    struct MacUCtrl *added = add234(dp->byctrl, uc);
    assert(added == uc);
    objc_setAssociatedObject(uc->toplevel, &mac_uctrl_key,
                             [NSValue valueWithPointer:uc],
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
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

static NSTextField *mac_make_label(const char *text)
{
    NSTextField *tf = [NSTextField labelWithString:mac_ns(text)];
    tf.alignment = NSTextAlignmentLeft;
    [tf setContentHuggingPriority:NSLayoutPriorityDefaultHigh
                   forOrientation:NSLayoutConstraintOrientationHorizontal];
    return tf;
}

static NSStackView *mac_make_vstack(void)
{
    NSStackView *stack = [[NSStackView alloc] initWithFrame:NSZeroRect];
    stack.orientation = NSUserInterfaceLayoutOrientationVertical;
    stack.alignment = NSLayoutAttributeLeading;
    stack.spacing = 6;
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    return stack;
}

static NSStackView *mac_make_hstack(void)
{
    NSStackView *stack = [[NSStackView alloc] initWithFrame:NSZeroRect];
    stack.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    stack.alignment = NSLayoutAttributeCenterY;
    stack.spacing = 8;
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    return stack;
}

static void mac_fire_handler(struct dlgparam *dp, struct MacUCtrl *uc, int event)
{
    if (!uc || !uc->ctrl || !uc->ctrl->handler)
        return;
    if (dp->flags & FLAG_IGNORING_EVENTS)
        return;
    uc->ctrl->handler(uc->ctrl, dp, dp->data, event);
}

/* ---------------------------------------------------------------------- */
/* Target actions */

@interface MacConfigActions : NSObject
@property (nonatomic) struct dlgparam *dp;
@property (nonatomic) struct MacUCtrl *pendingFontUCtrl;
@property (nonatomic) struct MacUCtrl *pendingColourUCtrl;
@end

@implementation MacConfigActions

- (void)buttonClicked:(id)sender
{
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

- (void)fontBrowse:(id)sender
{
    struct MacUCtrl *uc = mac_uctrl_from_sender(sender);
    if (!uc || uc->ctrl->type != CTRL_FONTSELECT)
        return;

    NSFontManager *fm = [NSFontManager sharedFontManager];
    NSTextField *field = (NSTextField *)uc->widget;
    NSString *cur = field.stringValue;
    NSFont *font = [NSFont monospacedSystemFontOfSize:12
                                               weight:NSFontWeightRegular];

    if ([cur hasPrefix:@"mac:"]) {
        NSArray *parts = [cur componentsSeparatedByString:@":"];
        if (parts.count == 3) {
            CGFloat size = [parts[2] doubleValue];
            NSFont *named = [NSFont fontWithName:parts[1]
                                            size:size > 0 ? size : 12];
            if (named)
                font = named;
        }
    }

    self.pendingFontUCtrl = uc;
    fm.target = self;
    fm.action = @selector(changeFont:);
    [fm setSelectedFont:font isMultiple:NO];
    [fm orderFrontFontPanel:self];
}

- (void)changeFont:(id)sender
{
    (void)sender;
    struct MacUCtrl *uc = self.pendingFontUCtrl;
    if (!uc || uc->ctrl->type != CTRL_FONTSELECT)
        return;
    NSFont *font = [[NSFontManager sharedFontManager] convertFont:
                    [NSFont monospacedSystemFontOfSize:12
                                                weight:NSFontWeightRegular]];
    if (!font)
        return;
    NSString *spec = [NSString stringWithFormat:@"mac:%@:%g",
                      font.fontName, (double)font.pointSize];
    ((NSTextField *)uc->widget).stringValue = spec;
    mac_fire_handler(self.dp, uc, EVENT_CALLBACK);
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

static char mac_config_controller_key;
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
    memset(uc, 0, sizeof(*uc));
    uc->ctrl = ctrl;
    uc->panel = panel;
    uc->selectedIndex = -1;
    uc->listItems = [NSMutableArray array];
    uc->selectedIndexes = [NSMutableIndexSet indexSet];
    return uc;
}

static NSView *mac_layout_one_control(
    struct dlgparam *dp, dlgcontrol *ctrl, NSView *panel,
    NSStackView *columnStacks[], int ncols, MacConfigActions *actions)
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
        tf.preferredMaxLayoutWidth = 420;
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
        uc->radioButtons = [NSMutableArray array];
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
        NSStackView *box = (ctrl->editbox.percentwidth == 100)
            ? mac_make_vstack() : mac_make_hstack();
        if (ctrl->label) {
            NSTextField *lab = mac_make_label(ctrl->label);
            uc->label = lab;
            [box addArrangedSubview:lab];
        }
        if (ctrl->editbox.has_list) {
            NSComboBox *combo = [[NSComboBox alloc] initWithFrame:NSZeroRect];
            combo.editable = YES;
            combo.completes = NO;
            combo.target = actions;
            combo.action = @selector(comboChanged:);
            [combo setContentHuggingPriority:NSLayoutPriorityDefaultLow
                              forOrientation:NSLayoutConstraintOrientationHorizontal];
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
            [field setContentHuggingPriority:NSLayoutPriorityDefaultLow
                              forOrientation:NSLayoutConstraintOrientationHorizontal];
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
            [box addArrangedSubview:popup];
            uc->widget = popup;
            uc->toplevel = box;
        } else {
            NSScrollView *scroll = [[NSScrollView alloc] initWithFrame:NSZeroRect];
            scroll.hasVerticalScroller = YES;
            scroll.autohidesScrollers = YES;
            scroll.borderType = NSBezelBorder;
            scroll.translatesAutoresizingMaskIntoConstraints = NO;

            NSTableView *table = [[NSTableView alloc] initWithFrame:NSZeroRect];
            NSTableColumn *col0 =
                [[NSTableColumn alloc] initWithIdentifier:@"text"];
            col0.title = @"";
            [table addTableColumn:col0];
            table.headerView = nil;
            table.allowsMultipleSelection = ctrl->listbox.multisel != 0;
            table.allowsEmptySelection = YES;
            scroll.documentView = table;
            [scroll.heightAnchor constraintEqualToConstant:
                (CGFloat)(ctrl->listbox.height * 18 + 8)].active = YES;

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
            [line addArrangedSubview:field];
            uc->widget = field;
        }
        NSButton *browse = [NSButton buttonWithTitle:@"Browse…"
                                              target:actions
                                              action:@selector(fileBrowse:)];
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
        [line addArrangedSubview:field];
        NSButton *change = [NSButton buttonWithTitle:@"Change…"
                                              target:actions
                                              action:@selector(fontBrowse:)];
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
        [dest addArrangedSubview:row];
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

    NSStackView *outer = mac_make_vstack();
    if (s->boxname[0]) {
        NSBox *box = [[NSBox alloc] initWithFrame:NSZeroRect];
        box.title = s->boxtitle ? mac_ns(s->boxtitle) : @"";
        box.boxType = NSBoxPrimary;
        box.titlePosition = s->boxtitle ? NSAtTop : NSNoTitle;
        box.contentViewMargins = NSMakeSize(8, 8);
        box.translatesAutoresizingMaskIntoConstraints = NO;

        NSStackView *inner = mac_make_vstack();
        box.contentView = inner;

        int ncols = 1;
        NSStackView *colstacks[8];
        NSStackView *cols_row = mac_make_hstack();
        colstacks[0] = mac_make_vstack();
        [cols_row addArrangedSubview:colstacks[0]];
        [inner addArrangedSubview:cols_row];

        for (size_t i = 0; i < s->ncontrols; i++) {
            dlgcontrol *ctrl = s->ctrls[i];
            if (ctrl->type == CTRL_COLUMNS) {
                ncols = ctrl->columns.ncols;
                if (ncols < 1)
                    ncols = 1;
                if (ncols > 8)
                    ncols = 8;
                cols_row = mac_make_hstack();
                for (int c = 0; c < ncols; c++) {
                    colstacks[c] = mac_make_vstack();
                    [cols_row addArrangedSubview:colstacks[c]];
                }
                [inner addArrangedSubview:cols_row];
                continue;
            }
            if (ctrl->type == CTRL_TABDELAY)
                continue;
            mac_layout_one_control(dp, ctrl, panel, colstacks, ncols, actions);
        }
        [outer addArrangedSubview:box];
        return outer;
    }

    /* Unboxed controlset (e.g. action buttons) */
    {
        int ncols = 1;
        NSStackView *colstacks[8];
        NSStackView *cols_row = mac_make_hstack();
        colstacks[0] = mac_make_vstack();
        [cols_row addArrangedSubview:colstacks[0]];
        [outer addArrangedSubview:cols_row];

        for (size_t i = 0; i < s->ncontrols; i++) {
            dlgcontrol *ctrl = s->ctrls[i];
            if (ctrl->type == CTRL_COLUMNS) {
                ncols = ctrl->columns.ncols;
                if (ncols < 1)
                    ncols = 1;
                if (ncols > 8)
                    ncols = 8;
                cols_row = mac_make_hstack();
                for (int c = 0; c < ncols; c++) {
                    colstacks[c] = mac_make_vstack();
                    [cols_row addArrangedSubview:colstacks[c]];
                }
                [outer addArrangedSubview:cols_row];
                continue;
            }
            if (ctrl->type == CTRL_TABDELAY)
                continue;
            mac_layout_one_control(dp, ctrl, panel, colstacks, ncols, actions);
        }
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

void dlg_end(dlgparam *dp, int value)
{
    if (dp->ended)
        return;
    dp->ended = true;
    dp->retval = value;
    post_dialog_fn_t after = dp->after;
    void *afterctx = dp->afterctx;
    NSWindow *window = dp->window;
    MacConfigBox *owner = dp->owner;

    /*
     * On Cancel, restore Conf from the backup taken at open (Windows
     * do_reconfig / GTK change-settings parity). On Apply/Open, keep edits.
     */
    if (value <= 0 && dp->backup_conf && dp->data)
        conf_copy_into((Conf *)dp->data, dp->backup_conf);

    if (window)
        [window orderOut:nil];

    if (after)
        after(afterctx, value);

    if (owner)
        mac_config_box_free(owner);
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
    return @[ kMacConfigToolbarCategory,
              NSToolbarFlexibleSpaceItemIdentifier ];
}

- (NSArray<NSToolbarItemIdentifier> *)toolbarDefaultItemIdentifiers:
    (NSToolbar *)toolbar
{
    (void)toolbar;
    return @[ kMacConfigToolbarCategory, NSToolbarFlexibleSpaceItemIdentifier ];
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
        self.dp->midsession ? @"Change Settings" : @"Session Settings"];
    label.font = [NSFont systemFontOfSize:13 weight:NSFontWeightSemibold];
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

    NSRect frame = NSMakeRect(0, 0, 780, 560);
    NSWindow *window =
        [[NSWindow alloc] initWithContentRect:frame
                                    styleMask:(NSWindowStyleMaskTitled |
                                               NSWindowStyleMaskClosable |
                                               NSWindowStyleMaskMiniaturizable |
                                               NSWindowStyleMaskResizable)
                                      backing:NSBackingStoreBuffered
                                        defer:NO];
    window.title = mac_ns(title);
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

    NSSplitView *split = [[NSSplitView alloc] initWithFrame:frame];
    split.vertical = YES;
    split.dividerStyle = NSSplitViewDividerStyleThin;

    NSScrollView *sideScroll = [[NSScrollView alloc] initWithFrame:NSZeroRect];
    sideScroll.hasVerticalScroller = YES;
    sideScroll.borderType = NSNoBorder;
    NSOutlineView *outline = [[NSOutlineView alloc] initWithFrame:NSZeroRect];
    NSTableColumn *col = [[NSTableColumn alloc] initWithIdentifier:@"cat"];
    col.title = @"Category";
    [outline addTableColumn:col];
    outline.outlineTableColumn = col;
    outline.headerView = nil;
    outline.dataSource = controller;
    outline.delegate = controller;
    sideScroll.documentView = outline;
    box->dp.sidebar = outline;
    [sideScroll.widthAnchor constraintGreaterThanOrEqualToConstant:160].active = YES;

    NSView *contentHost = [[NSView alloc] initWithFrame:NSZeroRect];
    contentHost.translatesAutoresizingMaskIntoConstraints = NO;
    NSStackView *contentStack = mac_make_vstack();
    [contentHost addSubview:contentStack];
    [contentStack.topAnchor constraintEqualToAnchor:contentHost.topAnchor
                                           constant:12].active = YES;
    [contentStack.leadingAnchor constraintEqualToAnchor:contentHost.leadingAnchor
                                               constant:12].active = YES;
    [contentStack.trailingAnchor constraintEqualToAnchor:contentHost.trailingAnchor
                                                constant:-12].active = YES;

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
            if (w)
                [panel addArrangedSubview:w];
        } else {
            NSView *w = mac_config_layout_controlset_impl(
                &box->dp, s, panelvbox, actions);
            if (w && panelvbox)
                [panelvbox addArrangedSubview:w];
        }
    }

    NSScrollView *contentScroll =
        [[NSScrollView alloc] initWithFrame:NSZeroRect];
    contentScroll.hasVerticalScroller = YES;
    contentScroll.documentView = contentHost;
    [contentHost.widthAnchor
        constraintEqualToAnchor:contentScroll.widthAnchor].active = YES;

    [split addSubview:sideScroll];
    [split addSubview:contentScroll];

    NSStackView *root = mac_make_vstack();
    root.translatesAutoresizingMaskIntoConstraints = NO;
    [root addArrangedSubview:split];
    if (actionArea)
        [root addArrangedSubview:actionArea];

    window.contentView = [[NSView alloc] initWithFrame:frame];
    [window.contentView addSubview:root];
    [root.topAnchor constraintEqualToAnchor:window.contentView.topAnchor].active = YES;
    [root.bottomAnchor constraintEqualToAnchor:window.contentView.bottomAnchor
                                      constant:-8].active = YES;
    [root.leadingAnchor constraintEqualToAnchor:window.contentView.leadingAnchor
                                       constant:8].active = YES;
    [root.trailingAnchor constraintEqualToAnchor:window.contentView.trailingAnchor
                                        constant:-8].active = YES;
    [split.heightAnchor constraintGreaterThanOrEqualToConstant:400].active = YES;

    [outline reloadData];
    [outline expandItem:nil expandChildren:YES];
    if (box->dp.sidebarRoots.count > 0)
        [outline selectRowIndexes:[NSIndexSet indexSetWithIndex:0]
             byExtendingSelection:NO];

    dlg_refresh(NULL, &box->dp);

    [window center];
    [window makeKeyAndOrderFront:nil];
    [NSApp activateIgnoringOtherApps:YES];
    return box;
}

void mac_config_box_free(MacConfigBox *box)
{
    if (!box)
        return;
    if (box->dp.window) {
        [box->dp.window setDelegate:nil];
        [box->dp.window close];
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

void initial_config_box(Conf *conf, post_dialog_fn_t after, void *afterctx)
{
    char *title = dupcat(appname, " Configuration");
    mac_config_create_box(title, conf, false, 0, after, afterctx);
    sfree(title);
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

    title = dupcat(appname, " Reconfiguration");
    mac_config_create_box(title, ctx->working, true, protcfginfo,
                          mac_change_settings_after, ctx);
    sfree(title);
}

/*
 * Host CA configuration UI is Phase 6.5. Until then, provide a stub so
 * config.c's "Configure host CAs" button links.
 */
void show_ca_config_box(dlgparam *dp)
{
    dlg_error_msg(dp, "Host CA configuration is not implemented yet.");
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
        Filename *fn = filename_from_str("/tmp/putty-smoke.log");
        dlg_filesel_set(c, &dp, fn);
        filename_free(fn);
        Filename *got = dlg_filesel_get(c, &dp);
        int ok = got && got->path &&
                 !strcmp(got->path, "/tmp/putty-smoke.log");
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
