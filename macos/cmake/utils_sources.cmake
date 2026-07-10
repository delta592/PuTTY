# macos/cmake/utils_sources.cmake
#
# Explicit list of platform utility sources for PUTTY_MACOS_GUI builds.
#
# Most entries are symlinks under macos/utils/ -> unix/utils/*.c so the
# shared Unix implementations are reused without pulling in GTK-only code.
# macos-native replacements:
#   utils/filename.c  (UTF-8 NFC paths, Phase 2.4)
#   utils/fontspec.c  (mac:PostScriptName:pointSize, Phase 2.4)
#
# Deliberately excluded unix/utils/*.c (GTK / X11 GUI helpers only):
#   align_label_left.c, buildinfo_gtk_version.c, get_label_text_dimensions.c,
#   get_x11_display.c, our_dialog.c, string_width.c
#
# arm_arch_queries.c uses sysctl on Apple Silicon / macOS for AES/NEON/SHA
# feature detection (crypto fast paths). Header: macos/utils/arm_arch_queries.h

set(PUTTY_MACOS_UTILS_SOURCES
  utils/arm_arch_queries.c
  utils/block_signal.c
  utils/cloexec.c
  utils/cmdline_arg.c
  utils/dputs.c
  utils/filename.c
  utils/fontspec.c
  utils/getticks.c
  utils/get_username.c
  utils/keysym_to_unicode.c
  utils/make_dir_and_check_ours.c
  utils/make_dir_path.c
  utils/make_spr_sw_abort_errno.c
  utils/nonblock.c
  utils/open_for_write_would_lose_data.c
  utils/pgp_fingerprints.c
  utils/pollwrap.c
  utils/signal.c
  utils/subprocess_waiter.c
  utils/x11_ignore_error.c
  ../utils/ltime.c)
