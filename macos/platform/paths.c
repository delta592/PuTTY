/*
 * macos/platform/paths.c — home / Application Support path helpers.
 */

#include <pwd.h>
#include <stdlib.h>
#include <unistd.h>

#include "putty.h"
#include "paths.h"

char *putty_macos_home_directory(void)
{
    const char *home = getenv("HOME");
    struct passwd *pwd;

    if (home && *home)
        return dupstr(home);

    pwd = getpwuid(getuid());
    if (pwd && pwd->pw_dir && pwd->pw_dir[0])
        return dupstr(pwd->pw_dir);

    return dupstr("");
}

char *putty_macos_app_support_directory(void)
{
    char *home = putty_macos_home_directory();
    char *ret = dupprintf("%s/" PUTTY_MACOS_APP_SUPPORT_REL, home);
    sfree(home);
    return ret;
}

char *putty_macos_default_log_path(void)
{
    char *home = putty_macos_home_directory();
    char *ret = dupprintf("%s/" PUTTY_MACOS_DEFAULT_LOG_REL, home);
    sfree(home);
    return ret;
}
