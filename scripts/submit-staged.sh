#!/usr/bin/env bash
#
# Submits the multi-node build as four Slurm jobs chained by dependencies:
#
#   bin    ──▶  chrom (array, one task per chromosome)  ──▶  join  ──▶  index
#
# Run it on the build site's login node, from anywhere; it submits and
# returns. Each stage is scripts/build-staged.sh (see there for what it does).
#
#   scripts/submit-staged.sh -p compute001-006 -t 2-00:00:00 \
#       --seqfile ../seqfiles/<name>.txt --name <name> --out ../builds/<name>
#
# Options:
#   -p, --partition P      Slurm partition (required)
#   -A, --account A        Slurm account
#   -t, --time T           walltime for every stage (required unless each
#                          stage gets its own below)
#       --time-bin T, --time-chrom T, --time-join T, --time-index T
#   --seqfile F, --name N, --out DIR    as for build-release.sh (required)
#   --chrom-cpus N         CPUs per chromosome task (default 128: a whole node;
#                          64 runs two chromosomes per node, and so on)
#   --node-cpus N          CPUs of one node (default 128), for the whole-node stages
#   --tasks N              array size (default: the number of expected
#                          reference contigs, 25; tasks without a chromosome
#                          exit at once, so a pilot with --refContigs is fine)
#   --max-running N        run at most N chromosome tasks at once (array %N)
#   --shared               do not take whole nodes (--exclusive --mem=0): the
#                          stages then get only the CPUs asked for, and
#                          --stage-mem / --chrom-mem as memory. For shared
#                          clusters and for trying the chain on the toy.
#   --stage-mem M, --chrom-mem M   memory with --shared (e.g. 16G)
#   --from STAGE           start the chain at STAGE (bin, chrom, join, index),
#                          to resume after a failure; earlier stages are not
#                          submitted. Steps already done are skipped anyway.
#   --dry-run              print the sbatch commands instead of running them
#
# Everything else the build reads (CACTUS_EXTRA, RELEASE_LABEL, BUILD_NOTE,
# WORKROOT, APPTAINER, ...) is taken from the environment of this shell, so
# values with commas or spaces need no quoting games:
#   export CACTUS_EXTRA='--refContigs chr21'
#
# Logs: <out>/logs/slurm/<stage>-<jobid>[_<task>].out; job ids in
# <out>/logs/slurm/jobs.txt. A failed stage leaves the later ones pending with
# DependencyNeverSatisfied: scancel them, fix the cause, and resubmit with
# --from <the failed stage>.
set -euo pipefail

REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
usage() { awk 'NR>1 && /^#/ { sub(/^# ?/, ""); print; next } NR>1 { exit }' "${BASH_SOURCE[0]}"; }

PART="" ACCOUNT="" TIME="" SEQFILE="" NAME="" OUT=""
declare -A STIME=()
CHROM_CPUS=128 NODE_CPUS=128 TASKS="" MAX_RUNNING="" FROM=bin DRY=0 SHARED=0 STAGE_MEM="" CHROM_MEM=""
while [ $# -gt 0 ]; do
    case $1 in
        -p|--partition) PART=$2; shift 2 ;;
        -A|--account) ACCOUNT=$2; shift 2 ;;
        -t|--time) TIME=$2; shift 2 ;;
        --time-bin|--time-chrom|--time-join|--time-index) STIME[${1#--time-}]=$2; shift 2 ;;
        --seqfile) SEQFILE=$2; shift 2 ;;
        --name) NAME=$2; shift 2 ;;
        --out) OUT=$2; shift 2 ;;
        --chrom-cpus) CHROM_CPUS=$2; shift 2 ;;
        --node-cpus) NODE_CPUS=$2; shift 2 ;;
        --tasks) TASKS=$2; shift 2 ;;
        --max-running) MAX_RUNNING=$2; shift 2 ;;
        --shared) SHARED=1; shift ;;
        --stage-mem) STAGE_MEM=$2; shift 2 ;;
        --chrom-mem) CHROM_MEM=$2; shift 2 ;;
        --from) FROM=$2; shift 2 ;;
        --dry-run) DRY=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *) echo "submit-staged.sh: unknown option $1" >&2; usage >&2; exit 2 ;;
    esac
done
[ -n "$PART" ] && [ -n "$SEQFILE" ] && [ -n "$NAME" ] && [ -n "$OUT" ] \
    || { echo "submit-staged.sh: -p, --seqfile, --name and --out are required" >&2; exit 2; }
case $FROM in bin|chrom|join|index) ;; *) echo "submit-staged.sh: --from bin|chrom|join|index" >&2; exit 2 ;; esac
for s in bin chrom join index; do
    : "${STIME[$s]:=$TIME}"
    [ -n "${STIME[$s]}" ] || { echo "submit-staged.sh: no walltime for $s (-t or --time-$s)" >&2; exit 2; }
done

SEQFILE=$(readlink -f "$SEQFILE")
[ -f "$SEQFILE" ] || { echo "submit-staged.sh: $SEQFILE not found" >&2; exit 1; }
mkdir -p "$OUT/logs/slurm"
OUT=$(cd "$OUT" && pwd)
if [ -z "$TASKS" ]; then
    if [ -n "${REF_CONTIGS:-}" ]; then TASKS=$(tr ',' '\n' <<< "$REF_CONTIGS" | grep -c .); else TASKS=25; fi
fi

# the seqfile is checked here, before anything queues
python3 "$REPO/scripts/check-seqfile.py" "$SEQFILE" ${REF_CONTIGS:+--ref-contigs "$REF_CONTIGS"}

L=$OUT/logs/slurm
common=(--parsable -p "$PART" ${ACCOUNT:+-A "$ACCOUNT"})
if [ "$SHARED" -eq 1 ]; then
    whole_node=(-c "$NODE_CPUS" ${STAGE_MEM:+--mem="$STAGE_MEM"})
    chrom_res=(-c "$CHROM_CPUS" ${CHROM_MEM:+--mem="$CHROM_MEM"})
else
    whole_node=(-c "$NODE_CPUS" --exclusive --mem=0)
    if [ "$CHROM_CPUS" -ge "$NODE_CPUS" ]; then
        chrom_res=(-c "$NODE_CPUS" --exclusive --mem=0)
    else
        chrom_res=(-c "$CHROM_CPUS")
    fi
fi

submit() {  # submit <stage> <dependency job id or ""> <extra sbatch args...>
    local stage=$1 dep=$2
    shift 2
    local cmd=(sbatch "${common[@]}" --job-name "pggl-$NAME-$stage" -t "${STIME[$stage]}"
               ${dep:+--dependency=afterok:$dep} "$@" --export="ALL,STAGE=$stage,SEQFILE=$SEQFILE,NAME=$NAME,OUT=$OUT,PGGL_GRAPH=$REPO"
               "$REPO/sbatch/stage.sbatch")
    if [ "$DRY" -eq 1 ]; then
        echo "${cmd[*]}" >&2
        echo "DRY-$stage"
    else
        "${cmd[@]}"
    fi
}

stages=(bin chrom join index)
started=0 dep="" ids=()
for s in "${stages[@]}"; do
    [ "$s" = "$FROM" ] && started=1
    [ "$started" -eq 1 ] || continue
    case $s in
        bin|join|index) id=$(submit "$s" "$dep" "${whole_node[@]}" -o "$L/$s-%j.out") ;;
        chrom) id=$(submit chrom "$dep" "${chrom_res[@]}" --array="0-$((TASKS - 1))${MAX_RUNNING:+%$MAX_RUNNING}" \
                         -o "$L/chrom-%A_%a.out") ;;
    esac
    id=${id%%;*}
    ids+=("$s=$id")
    dep=$id
done

printf '%s\t%s\n' "$(date -Is)" "${ids[*]}" >> "$L/jobs.txt"
echo "submitted: ${ids[*]}"
echo "logs:      $L/"
echo "watch:     squeue -u \$USER -n $(printf 'pggl-%s-%s,' "$NAME" bin "$NAME" chrom "$NAME" join "$NAME" index | sed 's/,$//')"
