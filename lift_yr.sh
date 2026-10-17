#!/bin/bash
# Lift Yuri's Revenge on its own, skipping setup.sh's tool check: the pipeline
# only needs python3 + pefile + capstone, and the 32-bit SDL2/ffmpeg it also
# asks for belong to the Linux *build*, which this machine cannot do (no root)
# and which the iOS port does not use.
set -e
cd "$(dirname "$0")"
T=../pcrecomp/tools
PY=${PY:-python3}
EXE=game/gamemd.exe
TARGET=${TARGET:-gamemd}
WORK=${WORK:-work}
GEN=${GEN:-src/recomp/gen}

step() { printf '\n=== %s  (%s)\n' "$*" "$(date '+%H:%M:%S')"; }

mkdir -p "$WORK"

[ -e "$WORK/pe_analysis.json" ] || { step "analysing $EXE"; "$PY" "$T/pe/pe_analyze.py" "$EXE" --json "$WORK/pe_analysis.json" >/dev/null; }
[ -e "$WORK/rtti_seeds.json" ]    || { step "RTTI"; "$PY" "$T/cpp/rtti.py" "$EXE" -o "$WORK/rtti.json" --seeds "$WORK/rtti_seeds.json" | tail -3; }
[ -e "$WORK/functions.json" ]     || { step "function catalog (about 15 minutes)"; "$PY" "$T/disasm/disasm32.py" "$EXE" -o "$WORK/functions.json" --seed-functions "$WORK/rtti_seeds.json" > "$WORK/disasm.log" 2>&1; grep -E "Functions:|coverage" "$WORK/disasm.log"; }

step "lifting to C (a minute or two)"
"$PY" run_lift.py --all --target "$TARGET" 2>&1 | tee "$WORK/lift.log" | grep -iE "lifted|error|warn" | tail -20

step "done: $GEN"
du -sh "$GEN" "$WORK" 2>/dev/null
wc -l "$GEN"/*.c 2>/dev/null | tail -1