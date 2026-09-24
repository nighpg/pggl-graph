#!/bin/bash
#SBATCH --job-name=pggl-graph-stage
#SBATCH --nodes=1
#
# One stage of the multi-node build (scripts/build-staged.sh). Submitted by
# scripts/submit-staged.sh, which sets the resources, the dependencies and
# these variables through --export:
#   STAGE     bin, chrom, join or index
#   SEQFILE, NAME, OUT, PGGL_GRAPH   absolute paths / the release name
# The images come from offline.env next to the checkout (OFFLINE_ENV to
# override). Other build variables (CACTUS_EXTRA, RELEASE_LABEL, ...) pass
# through from the submitting shell.
set -euo pipefail
trap 'echo "stage.sbatch: failed at line $LINENO: $BASH_COMMAND" >&2' ERR

: "${STAGE:?}" "${SEQFILE:?}" "${NAME:?}" "${OUT:?}" "${PGGL_GRAPH:?}"
OFFLINE_ENV=${OFFLINE_ENV:-$PGGL_GRAPH/offline.env}
if [ -f "$OFFLINE_ENV" ]; then
    set -a
    # shellcheck disable=SC1090
    . "$OFFLINE_ENV"
    set +a
fi

echo "host      : $(hostname)"
echo "job       : ${SLURM_JOB_ID:-none}${SLURM_ARRAY_TASK_ID:+ (array task $SLURM_ARRAY_TASK_ID)}"
echo "stage     : $STAGE"
echo "cpus / mem: ${SLURM_CPUS_PER_TASK:-?} / ${SLURM_MEM_PER_NODE:-not set by Slurm} MB"
echo "started   : $(date -Is)"
echo

rc=0
/usr/bin/time -v bash "$PGGL_GRAPH/scripts/build-staged.sh" "$STAGE" "$SEQFILE" "$NAME" "$OUT" || rc=$?
echo
echo "finished  : $(date -Is) (exit $rc)"
exit $rc
