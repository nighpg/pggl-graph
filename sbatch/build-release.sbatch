#!/bin/bash
#SBATCH --job-name=pggl-graph-build
#SBATCH --nodes=1
#SBATCH --exclusive
#SBATCH --mem=0
#
# Builds a release on one whole node with scripts/build-release.sh. Submit it
# from the pggl-graph checkout; partition, walltime and paths are given at
# submission:
#
#   cd /home/<user>/pangenome/pggl-graph
#   sbatch -p compute001-006 -c 128 -t <walltime> -o ../logs/build-%j.out \
#     --export=ALL,SEQFILE=<seqfile>,NAME=<name>,OUT=<outdir> \
#     sbatch/build-release.sbatch
#
# --exclusive --mem=0 takes the whole node; build-release.sh hands Toil and vg
# 95% of it. The images come from offline.env (setup-offline.sh writes it);
# OFFLINE_ENV points elsewhere. Every other build-release.sh variable
# (WORKROOT, JOBSTORE, RELEASE_LABEL, CACTUS_EXTRA, ...) passes through
# --export.
#
# Resubmitting the same command after a failure or a timeout resumes the
# build: Cactus restarts from its job store, or is skipped when it finished.
# The job store lives on node-local /scratch by default, so a resumed job must
# land on the same node (add -w <node>), or JOBSTORE must be on /home.
set -euo pipefail
trap 'echo "build-release.sbatch: failed at line $LINENO: $BASH_COMMAND" >&2' ERR

REPO=${PGGL_GRAPH:-$SLURM_SUBMIT_DIR}
[ -f "$REPO/scripts/build-release.sh" ] \
    || { echo "build-release.sbatch: submit from the pggl-graph checkout (or set PGGL_GRAPH)" >&2; exit 1; }
: "${SEQFILE:?set SEQFILE}"
: "${NAME:?set NAME}"
: "${OUT:?set OUT}"
OFFLINE_ENV=${OFFLINE_ENV:-$REPO/offline.env}
if [ -f "$OFFLINE_ENV" ]; then
    set -a
    # shellcheck disable=SC1090
    . "$OFFLINE_ENV"
    set +a
fi

echo "host      : $(hostname)"
echo "job       : ${SLURM_JOB_ID:-none}"
echo "cpus / mem: ${SLURM_CPUS_PER_TASK:-?} / ${SLURM_MEM_PER_NODE:-not set by Slurm; build-release.sh reads the cgroup or RAM} MB"
echo "repo      : $REPO @ $(git -C "$REPO" rev-parse --short HEAD 2>/dev/null || echo "${PGGL_GRAPH_REV:-unknown} (no git; from offline.env)")"
echo "seqfile   : $SEQFILE"
echo "output    : $OUT ($NAME)"
echo "started   : $(date -Is)"
echo

rc=0
/usr/bin/time -v bash "$REPO/scripts/build-release.sh" "$SEQFILE" "$NAME" "$OUT" || rc=$?
echo
echo "finished  : $(date -Is) (exit $rc)"
exit $rc
