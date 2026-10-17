/* ra2_entry.c - where the iOS app delegate starts the guest.
 *
 * HLEAppDelegate owns UIKit's main() and runs the game on its own pthread,
 * so the host's main() is compiled under the name ra2_host_main (build-ios.sh
 * passes -Dmain=ra2_host_main for src/linux/main.c alone). This file is the
 * join between them: it supplies the one argument list the host expects and
 * says where the game data lives.
 *
 * The data is not in the bundle. gamemd.exe and the .mix files are the
 * player's own copy of the game, several hundred megabytes, so they are put
 * in the app's Documents directory (enable File Sharing in the Info.plist and
 * iTunes/Files will show it) and read from there.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "ra2_paths.h"

int ra2_host_main(int argc, char **argv);

int hle_ios_run_guest(void) {
    /* --run is not the default: the host maps the image and exits without it. */
    static char *av[16];
    int n = 0;
    const char *game = 0;

    game = hle_ios_game_dir();

    av[n++] = (char *)"ra2";
    av[n++] = (char *)"--run";
    av[n++] = (char *)"--fullscreen";
    if (game) {
        av[n++] = (char *)"--game";
        av[n++] = (char *)game;
    }
    av[n] = 0;

    if (!game) {
        fprintf(stderr,
                "\n[ra2] No game folder. Copy the game's files into this app's\n"
                "      Documents/RedAlert2 folder (File Sharing must be on), or\n"
                "      set RA2_GAME_DIR in the environment to a folder that holds\n"
                "      %s and its .mix files.\n\n", RA2_EXE_NAME);
    }
    fprintf(stderr, "[ra2] starting, game folder %s\n", game ? game : "(none)");
    return ra2_host_main(n, av);
}