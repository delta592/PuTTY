/*
 * Placeholder for mac_gui_seat_list_head until Phase 5 implements seat.c.
 */

#include "putty.h"
#include "mac-gui-seat.h"

struct MacGuiSeatListNode mac_gui_seat_list_head = { &mac_gui_seat_list_head,
                                                     &mac_gui_seat_list_head };
