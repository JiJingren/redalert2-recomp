/* ra2_paths.c - finding the game's files on the device.
 *
 * iOS gives an app a per-install UUID path, so nothing here can be hardcoded.
 * HOME is the sandbox root and is set before any thread runs, so it is the
 * one thing that can be relied on. The search order is in ra2_paths.h.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/stat.h>

#include "ra2_paths.h"

static char g_dir[1024];

static int has_exe(const char *dir) {
    char p[1200];
    struct stat st;
    snprintf(p, sizeof p, "%s/%s", dir, RA2_EXE_NAME);
    return stat(p, &st) == 0 && S_ISREG(st.st_mode);
}

static int try_dir(const char *dir) {
    if (!dir || !*dir) return 0;
    if (!has_exe(dir)) return 0;
    snprintf(g_dir, sizeof g_dir, "%s", dir);
    return 1;
}

const char *hle_ios_game_dir(void) {
    static int looked = 0;
    const char *home;
    char p[1200];

    if (looked) return g_dir[0] ? g_dir : 0;
    looked = 1;

    if (try_dir(getenv("RA2_GAME_DIR"))) return g_dir;

    home = getenv("HOME");
    if (home && *home) {
        snprintf(p, sizeof p, "%s/Documents/RedAlert2", home);
        if (try_dir(p)) return g_dir;
        snprintf(p, sizeof p, "%s/Documents/Red Alert 2", home);
        if (try_dir(p)) return g_dir;
    }

    /* An app that shipped the data itself: next to the executable inside the
     * bundle, which is the only path the loader will let us read. */
    {
        char exe[1024];
        uint32_t n = (uint32_t)readlink("/proc/self/exe", exe, sizeof exe - 1);
        if (n > 0) {
            char *slash;
            exe[n] = 0;
            slash = strrchr(exe, '/');
            if (slash) {
                *slash = 0;
                snprintf(p, sizeof p, "%s/game", exe);
                if (try_dir(p)) return g_dir;
            }
        }
    }

    return g_dir[0] ? g_dir : 0;
}