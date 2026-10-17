/* ra2_paths.h - where the game data lives on the device. */
#pragma once

#include "recomp_target.h"

/* The folder holding gamemd.exe and the .mix files, or NULL when there is
 * none yet. RA2_GAME_DIR wins, then <Documents>/RedAlert2, then a `game`
 * folder inside the app bundle, which is where build-ios.sh puts it when it
 * is told to bundle the data (BUNDLE_GAME=1). */
const char *hle_ios_game_dir(void);