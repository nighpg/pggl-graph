#!/usr/bin/env bash
#
# Rebuilds tests/toy/expected/ -- a complete, validated release, small enough
# to check in -- from the assemblies in tests/toy/input/, with
# scripts/build-release.sh: the same script, and so the same code path, that
# builds a real release.
#
# Usage: tests/toy/build.sh <cactus.sif> <vg.sif> [workdir]
#   THREADS (default 8). The workdir (default: a new temporary directory) keeps
#   the Cactus outputs and logs.
#   TOY_MODE=update (default) replaces expected/ with the new release.
#   TOY_MODE=check leaves expected/ alone and compares the new release with
#   it: every file that builds reproducibly must be byte-identical (see
#   README.md), and validation must pass. This is the smoke test for a new
#   host, the air-gapped one included.
#   Regenerate the inputs first with make_inputs.py if the generator changed.
set -euo pipefail

CACTUS_SIF=${1:?usage: build.sh <cactus.sif> <vg.sif> [workdir]}
VG_SIF=${2:?usage: build.sh <cactus.sif> <vg.sif> [workdir]}
WORK=${3:-$(mktemp -d)}
TOY=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO=$(cd "$TOY/../.." && pwd)
mkdir -p "$WORK"
WORK=$(cd "$WORK" && pwd)
# a fresh build every time: no restart from an earlier run's job store
rm -rf "$WORK/cactus" "$WORK/release" "$WORK/work"

rc=0
CACTUS_SIF=$CACTUS_SIF VG_SIF=$VG_SIF THREADS=${THREADS:-8} MEM=${MEM:-16G} \
WORKROOT=$WORK/work REF_CONTIGS=chr20,chrX,chrY,chrM \
SITE=toy SITE_ROOT=. RELEASE_LABEL=toy \
BUILD_NOTE="tests/toy: synthetic assemblies from make_inputs.py" \
    bash "$REPO/scripts/build-release.sh" "$TOY/input/seqfile.txt" toy "$WORK" || rc=$?

if [ "${TOY_MODE:-update}" = check ]; then
    echo "== compare with expected/ ($(date -Is))"
    # the distance indexes and the minimizer index are not deterministic
    # across threads; everything else must come out byte for byte
    if [ ! -f "$WORK/release/graph.manifest.json" ]; then
        echo "BUILD FAILED (exit $rc) before a release was written; nothing to compare."
        echo "The cause is above; the Cactus log is $WORK/logs/cactus.log"
        exit 3
    fi
    diffs=0
    for f in "$TOY"/expected/toy.*; do
        b=$(basename "$f")
        case $b in *.dist|*.min) continue ;; esac
        if [ ! -f "$WORK/release/$b" ]; then
            echo "MISSING  $b"; diffs=$((diffs + 1))
        elif cmp -s "$f" "$WORK/release/$b"; then
            echo "same  $b"
        else
            echo "DIFF  $b"; diffs=$((diffs + 1))
        fi
    done
    echo "validation: exit $rc; differing or missing files: $diffs"
    echo "workdir: $WORK"
    [ "$rc" -eq 0 ] && [ "$diffs" -eq 0 ] && exit 0
    exit 3
fi

echo "== expected/ ($(date -Is))"
rm -rf "$TOY/expected"
mkdir -p "$TOY/expected"
cp "$WORK"/release/toy.* "$WORK/release/graph.manifest.json" "$TOY/expected/"
cp "$WORK/release/validation/validation.log" "$TOY/expected/"
echo "workdir: $WORK"
exit $rc
