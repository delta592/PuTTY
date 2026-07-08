/*
 * macos/platform.h — macOS-specific inter-module definitions.
 *
 * Phase 1.4: minimal compile-time definitions including BUILDINFO_PLATFORM.
 * Expanded in Phase 2.1.
 */

#ifndef PUTTY_MACOS_PLATFORM_H
#define PUTTY_MACOS_PLATFORM_H

#include <stdio.h>
#include <stdint.h>
#include <sys/types.h>
#ifndef NO_LIBDL
#include <dlfcn.h>
#endif
#include "charset.h"

#define BUILDINFO_PLATFORM "macOS (AppKit)"

#define NOT_X_WINDOWS
#define NO_PTY_PRE_INIT
#define SET_NONBLOCK_VIA_OPENPT

#define MULTICLICK_ONLY_EVENT 0

typedef void *HelpCtx;
#define NULL_HELPCTX ((HelpCtx)NULL)
#define HELPCTX(x) NULL

#define SELECTION_NUL_TERMINATED 1

#define SEL_NL { 13, 10 }

unsigned long getticks(void);
#define GETTICKCOUNT getticks
#define TICKSPERSEC    1000
#define CURSORBLINK     450

#define WCHAR wchar_t
#define BYTE unsigned char

#define PLATFORM_CLIPBOARDS(X)                            \
    X(CLIP_CLIPBOARD, "system clipboard")                 \
    X(CLIP_CUSTOM_1, "Find pasteboard")                   \
    /* end of list */

#define MOUSE_SELECT_CLIPBOARD CLIP_LOCAL
#define MOUSE_PASTE_CLIPBOARD CLIP_CLIPBOARD
#define CLIPNAME_IMPLICIT "Last selected text"
#define CLIPNAME_EXPLICIT "System clipboard"
#define CLIPNAME_EXPLICIT_OBJECT "system clipboard"
#define CLIPUI_DEFAULT_AUTOCOPY false
#define CLIPUI_DEFAULT_MOUSE CLIPUI_EXPLICIT
#define CLIPUI_DEFAULT_INS CLIPUI_EXPLICIT
#define MENU_CLIPBOARD CLIP_CLIPBOARD
#define COPYALL_CLIPBOARDS CLIP_CLIPBOARD

struct Filename {
    char *path;
};
FILE *f_open(const Filename *filename, char const *mode, bool private);

#ifndef SUPERSEDE_FONTSPEC_FOR_TESTING
struct FontSpec {
    char *name;
};
FontSpec *fontspec_new(const char *name);
#endif

extern const struct BackendVtable pty_backend;

#define BROKEN_PIPE_ERROR_CODE EPIPE

#define DEFAULT_CODEPAGE 0xFFFF
#define CP_UTF8 CS_UTF8
#define CP_437 CS_CP437
#define CP_ISO8859_1 CS_ISO8859_1

#define strnicmp strncasecmp
#define stricmp strcasecmp

void (*putty_signal(int sig, void (*func)(int)))(int);
void block_signal(int sig, bool block_it);

void cloexec(int fd);
void noncloexec(int fd);
bool nonblock(int fd);
bool no_nonblock(int fd);
char *make_dir_and_check_ours(const char *dirname);
char *make_dir_path(const char *path, mode_t mode);

bool init_ucs(struct unicode_data *ucsdata, char *line_codepage,
              bool utf8_override, int font_charset, int vtmode);

void *sk_getxdmdata(Socket *sock, int *lenp);
int sk_net_get_fd(Socket *sock);
SockAddr *unix_sock_addr(const char *path);
Socket *new_unix_listener(SockAddr *listenaddr, Plug *plug);

#define FD_SET_MAX(fd, max, set) do { \
    FD_SET(fd, &set); \
    if (max < fd + 1) max = fd + 1; \
} while (0)

extern const struct BackendVtable serial_backend;

bool so_peercred(int fd, int *pid, int *uid, int *gid);

Socket *make_fd_socket(int infd, int outfd, int inerrfd,
                       SockAddr *addr, int port, Plug *plug);
Socket *make_deferred_fd_socket(DeferredSocketOpener *opener,
                                SockAddr *addr, int port, Plug *plug);
void setup_fd_socket(Socket *s, int infd, int outfd, int inerrfd);
void fd_socket_set_psb_prefix(Socket *s, const char *prefix);

#define DEFAULT_GTK_CLIENT_FONT "SF Mono 12"
#define DEFAULT_GTK_SERVER_FONT "SF Mono 12"
#define DEFAULT_GTK_FONT DEFAULT_GTK_CLIENT_FONT

void pty_pre_init(void);
extern char **pty_argv;

bool socket_peer_is_same_user(int fd);
static inline bool sk_peer_trusted(Socket *sock)
{
    int fd = sk_net_get_fd(sock);
    return fd >= 0 && socket_peer_is_same_user(fd);
}

extern const SftpServerVtable unix_live_sftpserver_vt;

typedef struct pollwrapper pollwrapper;
pollwrapper *pollwrap_new(void);
void pollwrap_free(pollwrapper *pw);
void pollwrap_clear(pollwrapper *pw);
void pollwrap_add_fd_events(pollwrapper *pw, int fd, int events);
void pollwrap_add_fd_rwx(pollwrapper *pw, int fd, int rwx);
int pollwrap_poll_instant(pollwrapper *pw);
int pollwrap_poll_endless(pollwrapper *pw);
int pollwrap_poll_timeout(pollwrapper *pw, int milliseconds);
int pollwrap_get_fd_events(pollwrapper *pw, int fd);
int pollwrap_get_fd_rwx(pollwrapper *pw, int fd);
static inline bool pollwrap_check_fd_rwx(pollwrapper *pw, int fd, int rwx)
{
    return (pollwrap_get_fd_rwx(pw, fd) & rwx) != 0;
}

typedef bool (*cliloop_pw_setup_t)(void *ctx, pollwrapper *pw);
typedef void (*cliloop_pw_check_t)(void *ctx, pollwrapper *pw);
typedef bool (*cliloop_continue_t)(void *ctx, bool found_any_fd,
                                   bool ran_any_callback);

SubprocessWaiter *subproc_waiter_from_pid(pid_t pid);
void subproc_waiter_force_setup(void);
void subproc_waiter_force_wait(void);

void cli_main_loop(cliloop_pw_setup_t pw_setup,
                   cliloop_pw_check_t pw_check,
                   cliloop_continue_t cont, void *ctx);

bool cliloop_no_pw_setup(void *ctx, pollwrapper *pw);
void cliloop_no_pw_check(void *ctx, pollwrapper *pw);
bool cliloop_always_continue(void *ctx, bool found_any_fd,
                             bool ran_any_callback);

void plug_closing_errno(Plug *plug, int error);

SeatPromptResult make_spr_sw_abort_errno(const char *prefix, int errno_value);

CmdlineArgList *cmdline_arg_list_from_argv(int argc, char **argv);
char **cmdline_arg_remainder(CmdlineArg *argp);

typedef struct uxsel_id uxsel_id;
void uxsel_init(void);
typedef void (*uxsel_callback_fn)(int fd, int event);
void uxsel_set(int fd, int rwx, uxsel_callback_fn callback);
void uxsel_del(int fd);
enum { SELECT_R = 1, SELECT_W = 2, SELECT_X = 4 };
void select_result(int fd, int event);
int first_fd(int *state, int *rwx);
int next_fd(int *state, int *rwx);
uxsel_id *uxsel_input_add(int fd, int rwx);
void uxsel_input_remove(uxsel_id *id);

struct termios;
void stderr_tty_init(void);
void premsg(struct termios *oldtermios);
void postmsg(struct termios *oldtermios);

void setup(bool single_session_in_this_process);
void cleanup_exit(int code);
void cleanup_all(void);

char *x_get_default(const char *key);
void provide_xrm_string(const char *string, const char *progname);

#endif /* PUTTY_MACOS_PLATFORM_H */
