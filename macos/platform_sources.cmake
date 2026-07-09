# Reuse Unix platform C sources until Phase 2 migrates them into macos/platform/.

add_sources_from_current_dir(utils
  ../unix/utils/arm_arch_queries.c
  ../unix/utils/block_signal.c
  ../unix/utils/cloexec.c
  ../unix/utils/cmdline_arg.c
  ../unix/utils/dputs.c
  ../unix/utils/filename.c
  ../unix/utils/fontspec.c
  ../unix/utils/getticks.c
  ../unix/utils/get_username.c
  ../unix/utils/keysym_to_unicode.c
  ../unix/utils/make_dir_and_check_ours.c
  ../unix/utils/make_dir_path.c
  ../unix/utils/make_spr_sw_abort_errno.c
  ../unix/utils/nonblock.c
  ../unix/utils/open_for_write_would_lose_data.c
  ../unix/utils/pgp_fingerprints.c
  ../unix/utils/pollwrap.c
  ../unix/utils/signal.c
  ../unix/utils/subprocess_waiter.c
  ../unix/utils/x11_ignore_error.c
  ../utils/ltime.c)

add_sources_from_current_dir(eventloop
  ../unix/cliloop.c
  ../unix/uxsel.c)

add_sources_from_current_dir(console
  ../unix/console.c)

add_sources_from_current_dir(settings
  ../unix/storage.c
  platform/stubs.c
  platform/gui-seat-list.c)

add_sources_from_current_dir(network
  ../unix/network.c
  ../unix/fd-socket.c
  ../unix/agent-socket.c
  ../unix/peerinfo.c
  ../unix/local-proxy.c
  ../unix/x11.c)

add_sources_from_current_dir(sshcommon
  ../unix/noise.c)

add_sources_from_current_dir(sshclient
  ../unix/gss.c
  ../unix/agent-client.c
  ../unix/sharing.c)

add_sources_from_current_dir(sshserver
  ../unix/sftpserver.c
  ../unix/procnet.c)

add_sources_from_current_dir(sftpclient
  ../unix/sftp.c)

add_sources_from_current_dir(otherbackends
  ../unix/serial.c)

add_sources_from_current_dir(agent
  ../unix/agent-client.c)

add_sources_from_current_dir(plink
  ../unix/unicode.c
  ../unix/no-gtk.c)

add_sources_from_current_dir(pscp
  ../unix/unicode.c
  ../unix/no-gtk.c)

add_sources_from_current_dir(psftp
  ../unix/unicode.c
  ../unix/no-gtk.c)

add_sources_from_current_dir(psocks
  ../unix/no-gtk.c)

add_sources_from_current_dir(test_conf
  ../unix/unicode.c
  ../unix/stubs/no-uxsel.c)
