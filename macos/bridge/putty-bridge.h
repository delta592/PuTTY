/*
 * putty-bridge.h — public C API consumed by Swift (Phase 3).
 *
 * Phase 1.3: placeholder header so the PuttyBridge clang module can be
 * resolved by the Swift toolchain during CMake configuration.
 */

#ifndef PUTTY_MACOS_PUTTY_BRIDGE_H
#define PUTTY_MACOS_PUTTY_BRIDGE_H

#ifdef __cplusplus
extern "C" {
#endif

int putty_bridge_version(void);

#ifdef __cplusplus
}
#endif

#endif /* PUTTY_MACOS_PUTTY_BRIDGE_H */
