/*
 * macos/platform/paths.h — canonical PuTTY data locations on macOS.
 *
 * Non-sandboxed builds resolve under the user's home directory.
 * Sandboxed .app bundles (Phase 8/9) receive a container home from
 * the system; the same relative layout applies inside that container.
 */

#ifndef PUTTY_MACOS_PATHS_H
#define PUTTY_MACOS_PATHS_H

#define PUTTY_MACOS_APP_SUPPORT_REL "Library/Application Support/PuTTY"
#define PUTTY_MACOS_SESSIONS_DIRNAME "sessions"
#define PUTTY_MACOS_SSHHOSTKEYS_BASENAME "sshhostkeys"
#define PUTTY_MACOS_RANDOMSEED_BASENAME "putty.rnd"
#define PUTTY_MACOS_SSHHOSTCAS_DIRNAME "sshhostcas"

/* Default session log location when the user has not configured one. */
#define PUTTY_MACOS_DEFAULT_LOG_REL "Documents/putty.log"

char *putty_macos_home_directory(void);
char *putty_macos_app_support_directory(void);
char *putty_macos_default_log_path(void);

#endif /* PUTTY_MACOS_PATHS_H */
