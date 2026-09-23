#!/usr/bin/env bash
#
# COPY -- the master is nighpg/pggl-workflow scripts/vg-snarls.sh (copied at 6738d0e).
# Change it there first, then copy it here again; never edit only this copy.
#
# Snarls for a graph, consumed only by the workflows' call_sv track. A sampled
# graph needs its own: the snarls that ship with the full graph describe sites
# that sampling may have removed.
#
# Produces no output when not asked for, which is how the workflow expresses
# "off" (cwlVersion v1.1 has no conditional steps).
#
# Usage: vg-snarls.sh <gbz> <prefix> <threads> <enabled>
set -euo pipefail

GBZ=$1
PREFIX=$2
THREADS=$3
ENABLED=${4:-false}

if [ "$ENABLED" != "true" ]; then
    echo "vg-snarls.sh: not requested; skipping" >&2
    exit 0
fi

vg snarls -t "$THREADS" "$GBZ" > "${PREFIX}.snarls"
[ -s "${PREFIX}.snarls" ] || { echo "vg-snarls.sh: empty snarls" >&2; exit 1; }
