#!/usr/bin/env bash
#
# Builds a release on one node: Minigraph-Cactus (cactus-pangenome --mgSplit,
# in the Cactus image), then stages [D]-[E] (scripts/index-release.sh, in the
# per-sample vg image). No network is needed. tests/toy/build.sh runs this same
# script, so the toy exercises exactly the production code path.
#
# Usage: build-release.sh <seqfile> <name> <outdir>
#
#   <outdir>/cactus/     Cactus outputs (<name>.gfa.gz = clip, <name>.d2.gfa.gz
#                        = filter, <name>.full.hal, stats, <name>.WARNING)
#   <outdir>/release/    the release: <name>.{clip,filter}.*, <name>.ref.*,
#                        graph.manifest.json, validation/
#   <outdir>/logs/       cactus.log
#
# Environment (offline.env from setup-offline.sh provides the first two):
#   CACTUS_SIF, VG_SIF   the images (required)
#   THREADS              cores for Cactus and vg (default: the Slurm allocation, else nproc)
#   MEM                  memory ceiling for Toil and vg autoindex, e.g. 950G
#                        (default: 95% of what the job may use: the Slurm
#                        allocation, else the job's cgroup limit, else its
#                        CPU share of the RAM)
#   WORKROOT             fast local scratch for Toil's work dir and vg's
#                        temporaries (default: /scratch/$USER/pggl-graph-<name>
#                        when /scratch exists, else <outdir>/work)
#   JOBSTORE             Toil job store (default: $WORKROOT/jobstore). Put it on
#                        the shared filesystem to be able to restart on another node.
#   REF_CONTIGS          expected reference contigs (default: the 25 GRCh38
#                        primary contigs; see check-seqfile.py)
#   RELEASE_LABEL        manifest release label (default: today's date)
#   SITE, SITE_ROOT      manifest site name (default "build") and release root
#                        (default: the absolute release directory)
#   CACTUS_EXTRA         extra cactus-pangenome options, word-split
#   BUILD_NOTE           free text for the manifest's build.note
#
# Restarting: run the same command again. Cactus is skipped when both GFAs are
# already there, restarted from its job store (--restart) when that exists,
# and started afresh otherwise. The vg stages always rerun; they take hours at
# full scale against days for Cactus.
#
# Exit: validate-graph.sh's (0 pass, 3 a check failed), or the failing step's.
set -euo pipefail

SEQFILE=${1:?usage: build-release.sh <seqfile> <name> <outdir>}
NAME=${2:?usage: build-release.sh <seqfile> <name> <outdir>}
OUT=${3:?usage: build-release.sh <seqfile> <name> <outdir>}
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
SCRIPT=build-release.sh
# shellcheck source=lib/build-common.sh
. "$HERE/lib/build-common.sh"
JOBSTORE=${JOBSTORE:-$WORKROOT/jobstore}
mkdir -p "$(dirname "$JOBSTORE")"

log "build-release.sh $NAME: $THREADS threads, $MEM, work in $WORKROOT, job store $JOBSTORE"
log "images: $(basename "$CACTUS_SIF"), $(basename "$VG_SIF")"

# --- preflight --------------------------------------------------------------
preflight

# --- [A]-[C]: Minigraph-Cactus ------------------------------------------------
CACTUS_OPTS=(--reference GRCh38 --mgSplit --gfa clip filter)
if [ -s "$OUT/cactus/$NAME.gfa.gz" ] && [ -s "$OUT/cactus/$NAME.d2.gfa.gz" ]; then
    log "Cactus outputs present; skipping cactus-pangenome"
else
    restart=()
    if [ -d "$JOBSTORE" ]; then
        log "job store exists: restarting cactus-pangenome"
        restart=(--restart)
    else
        log "cactus-pangenome"
    fi
    # shellcheck disable=SC2086
    "$AP" exec --cleanenv --bind "$(binds "$OUT" "$WORKROOT" "$(dirname "$JOBSTORE")" "$INPUT_DIRS")" "$CACTUS_SIF" \
        cactus-pangenome "$JOBSTORE" "$OUT/cactus.seqfile.txt" \
        --outDir "$OUT/cactus" --outName "$NAME" "${CACTUS_OPTS[@]}" \
        --binariesMode local --maxCores "$THREADS" --maxMemory "$MEM" \
        --workDir "$WORKROOT/toil" --logFile "$OUT/logs/cactus.log" \
        "${restart[@]}" ${CACTUS_EXTRA:-}
    [ -f "$OUT/cactus/$NAME.WARNING" ] && { log "Cactus left a warning:"; cat "$OUT/cactus/$NAME.WARNING"; }
fi
write_build_info "cactus-pangenome on one node (build-release.sh)"

# --- [D]-[E]: vg indexes, reference, manifest, validation ------------------
log "index-release.sh"
rc=0
run_index_release || rc=$?
log "done: $OUT/release (exit $rc)"
exit $rc
