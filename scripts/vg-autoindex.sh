#!/usr/bin/env bash
#
# COPY -- the master is nighpg/pggl-workflow scripts/vg-autoindex.sh (copied at 6738d0e).
# Change it there first, then copy it here again; never edit only this copy.
#
# Builds the giraffe index set for a graph. Used for a personalized graph, which
# scripts/prepare_pangenome_indexes.sh cannot handle: that script also derives a
# ref_paths list from full-length reference paths, and a sampled graph carries
# the reference as subranges, so it stops with "only N full-length paths". The
# ref_paths input is unaffected by sampling and is reused as is.
#
# vg names its outputs after the workflow it built them for; they are renamed to
# the plain .min/.zipcodes the CWL tools expect.
#
# Usage: vg-autoindex.sh <gbz> <prefix> <threads> [target_mem]
set -euo pipefail

GBZ=$1
PREFIX=$2
THREADS=$3
TARGET_MEM=${4:-}

# vg spills large intermediates; keep them where the runner put the job, not in
# a node-local /tmp that is often far too small.
: "${TMPDIR:=$PWD/autoindex_tmp}"
mkdir -p "$TMPDIR"

ARGS=( -p "$PREFIX" -G "$GBZ" -w giraffe -t "$THREADS" -T "$TMPDIR" )
[ -n "$TARGET_MEM" ] && ARGS+=( -M "$TARGET_MEM" )

vg autoindex "${ARGS[@]}"

[ -f "${PREFIX}.min" ]      || mv "${PREFIX}.shortread.withzip.min" "${PREFIX}.min"
[ -f "${PREFIX}.zipcodes" ] || mv "${PREFIX}.shortread.zipcodes" "${PREFIX}.zipcodes"

for f in dist min zipcodes; do
    [ -s "${PREFIX}.${f}" ] || { echo "vg-autoindex.sh: ${PREFIX}.${f} missing" >&2; exit 1; }
done
