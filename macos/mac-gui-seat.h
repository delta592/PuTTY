/*
 * macos/mac-gui-seat.h — opaque GUI front-end types for the AppKit port.
 *
 * MacTermWin is defined in macos/platform/termwin.h (Phase 4.1).
 * MacGuiSeat will be defined in macos/platform/seat.c (Phase 5).
 * This header exposes only what other translation units
 * need for pointers and list management.
 */

#ifndef PUTTY_MACOS_MAC_GUI_SEAT_H
#define PUTTY_MACOS_MAC_GUI_SEAT_H

typedef struct MacGuiSeat MacGuiSeat;
typedef struct MacTermWin MacTermWin;

/*
 * Linked list of live MacGuiSeat instances (mirrors WinGuiSeat list in
 * windows/win-gui-seat.h) so process-wide cleanup can reach every window.
 */
struct MacGuiSeatListNode {
    struct MacGuiSeatListNode *next, *prev;
};
extern struct MacGuiSeatListNode mac_gui_seat_list_head;

#endif /* PUTTY_MACOS_MAC_GUI_SEAT_H */
