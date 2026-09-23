#!/bin/bash
#SBATCH --job-name=validate-graph
#SBATCH --cpus-per-task=16
#SBATCH --mem=128G
#SBATCH --time=04:00:00
#
# Runs scripts/validate-graph.sh inside the per-sample vg image. Partition and
# account are site-specific, so they are given on the command line:
#
#   sbatch -p <partition> [-A <account>] -o <log> \
#     --export=ALL,VG_SIF=<vg.sif>,MANIFEST=<graph.manifest.json>,SITE=<site>,OUT=<dir> \
#     sbatch/validate-graph.sbatch
#
# Memory: check 5 holds the giraffe index set in memory, so it needs roughly
# min + dist + gbz (JaSaPaGe: 38 + 7.6 + 3.3 GB) plus headroom.
set -euo pipefail

: "${VG_SIF:?set VG_SIF to the image with the per-sample vg}"
: "${MANIFEST:?set MANIFEST to the graph.manifest.json to validate}"
: "${SITE:?set SITE to the manifest site this host sees}"
: "${OUT:?set OUT to the output directory}"

REPO=$(cd "$(dirname "$(readlink -f "$MANIFEST")")" && git rev-parse --show-toplevel)
AP=${APPTAINER:-$(command -v apptainer)}
ROOT_DIRS=$(python3 "$REPO/scripts/manifest.py" resolve "$MANIFEST" --site "$SITE" \
            | sed -n 's/^ROOT_DIRS=//p' | tr -d "'")
mkdir -p "$OUT"

echo "host      : $(hostname)"
echo "job       : ${SLURM_JOB_ID:-none}"
echo "cpus / mem: ${SLURM_CPUS_PER_TASK:-?} / ${SLURM_MEM_PER_NODE:-?} MB"
echo "image     : $VG_SIF"
echo "manifest  : $MANIFEST (site $SITE)"
echo "repo      : $REPO @ $(git -C "$REPO" rev-parse --short HEAD)"
echo "started   : $(date -Is)"
echo

rc=0
/usr/bin/time -v "$AP" exec --cleanenv \
    --bind "$REPO,$OUT,$ROOT_DIRS" \
    --env THREADS="${SLURM_CPUS_PER_TASK:-8}",PGGL_GRAPH_REV="$(git -C "$REPO" rev-parse --short HEAD)",TMPDIR="$OUT" \
    "$VG_SIF" \
    bash "$REPO/scripts/validate-graph.sh" "$(readlink -f "$MANIFEST")" "$SITE" "$OUT" || rc=$?

echo
echo "finished  : $(date -Is) (exit $rc)"
exit $rc
