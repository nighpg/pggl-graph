#!/usr/bin/env bash
#
# One stage of the multi-node build. scripts/submit-staged.sh submits the four
# stages as Slurm jobs chained by dependencies; each stage can also be run by
# hand, in order. Together they produce what build-release.sh produces on one
# node, with the per-chromosome work spread over nodes:
#
#   bin     1 job     input contig sizes (for the exclusion report), then
#                     cactus-minigraph --refOnly, cactus-graphmap --mgSplit,
#                     cactus-graphmap-split --mgSplit: bins every contig to a
#                     chromosome, and lists the chromosomes largest first
#   chrom   array     one task per chromosome: cactus-minigraph, cactus-graphmap
#                     and cactus-align (--pangenome), each with --batch on a
#                     one-chromosome chromfile. Task i takes the i-th largest;
#                     tasks beyond the number of chromosomes exit at once.
#   join    1 job     cactus-graphmap-join: the clip and filter GFAs, the HAL,
#                     the exclusion report
#   index   1 job     index-release.sh in the vg image: GBZs, indexes,
#                     reference, manifest, validation (as build-release.sh)
#
# These are the steps cactus-pangenome --mgSplit chains itself, with the same
# options; on the toy, the staged build reproduces its GBZs byte for byte.
#
# Usage: build-staged.sh <stage> <seqfile> <name> <outdir> [chromosome index]
#   The chromosome index defaults to SLURM_ARRAY_TASK_ID.
#
# Environment: as build-release.sh (CACTUS_SIF, VG_SIF, THREADS, MEM,
# WORKROOT, REF_CONTIGS, RELEASE_LABEL, SITE, SITE_ROOT, BUILD_NOTE), plus
#   CACTUS_EXTRA  extra options for every Cactus command of the stage
#
# Every Cactus step runs Toil on this node only, with its own job store under
# WORKROOT, and is skipped when its output exists. A failed step reruns from
# its own start: resubmitting the stage (or the whole chain) resumes there.
#
# Layout, all under <outdir> (shared by every node):
#   cactus/<name>.input-contig-sizes.tsv.gz, <name>.sv.gfa.gz, <name>.paf,
#   cactus/chrom-subproblems/          the bin stage
#   cactus/chroms.txt                  chromosomes, largest first
#   cactus/chroms/<chrom>/{minigraph,graphmap,align}/   the chrom tasks
#   cactus/<name>.gfa.gz, <name>.d2.gfa.gz, <name>.full.hal, ...   the join
#   release/                           the index stage
#   logs/<stage>/                      one Cactus log per step
set -euo pipefail

STAGE=${1:?usage: build-staged.sh <bin|chrom|join|index> <seqfile> <name> <outdir> [index]}
SEQFILE=${2:?usage: build-staged.sh <stage> <seqfile> <name> <outdir> [index]}
NAME=${3:?usage: build-staged.sh <stage> <seqfile> <name> <outdir> [index]}
OUT=${4:?usage: build-staged.sh <stage> <seqfile> <name> <outdir> [index]}
TASK=${5:-${SLURM_ARRAY_TASK_ID:-}}
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
SCRIPT="build-staged.sh $STAGE"
# shellcheck source=lib/build-common.sh
. "$HERE/lib/build-common.sh"
C=$OUT/cactus

log "build-staged.sh $STAGE $NAME${TASK:+ [task $TASK]}: $THREADS threads, $MEM, on $(hostname), work in $WORKROOT"

# Runs one Cactus command with a fresh job store; skipped when $1 exists.
# cactus_step <done-file> <step name> <command> <args...>
cactus_step() {
    local done=$1 step=$2
    shift 2
    if [ -e "$done" ]; then
        log "  $step: done already"
        return 0
    fi
    local js=$WORKROOT/js/$step
    rm -rf "$js"
    mkdir -p "$WORKROOT/js" "$OUT/logs/$STAGE"
    log "  $step: $1"
    # shellcheck disable=SC2086
    "$AP" exec --cleanenv --bind "$(binds "$OUT" "$WORKROOT" "$INPUT_DIRS" "$REPO")" "$CACTUS_SIF" \
        "$1" "$js" "${@:2}" \
        --binariesMode local --maxCores "$THREADS" --maxMemory "$MEM" \
        --workDir "$WORKROOT/toil" --logFile "$OUT/logs/$STAGE/$step.log" ${CACTUS_EXTRA:-}
    [ -e "$done" ] || { echo "$SCRIPT: $step finished but $done is missing" >&2; exit 1; }
    rm -rf "$js"
}

case $STAGE in
bin)
    preflight
    # Cactus adds the minigraph event to the seqfile it is given; keep the
    # user's untouched and hand Cactus its own copy
    [ -e "$C/$NAME.seqfile.txt" ] || cp "$OUT/cactus.seqfile.txt" "$C/$NAME.seqfile.txt"
    if [ ! -s "$C/$NAME.input-contig-sizes.tsv.gz" ]; then
        log "  contig sizes"
        "$AP" exec --cleanenv --bind "$(binds "$OUT" "$INPUT_DIRS" "$REPO")" "$CACTUS_SIF" \
            python3 "$REPO/scripts/cactus-contig-sizes.py" "$OUT/cactus.seqfile.txt" \
            "$C/$NAME.input-contig-sizes.tsv.gz.part" "$THREADS"
        mv "$C/$NAME.input-contig-sizes.tsv.gz.part" "$C/$NAME.input-contig-sizes.tsv.gz"
    fi
    cactus_step "$C/$NAME.sv.gfa.gz" minigraph \
        cactus-minigraph "$C/$NAME.seqfile.txt" "$C/$NAME.sv.gfa.gz" --reference GRCh38 --refOnly
    cactus_step "$C/$NAME.paf" graphmap \
        cactus-graphmap "$C/$NAME.seqfile.txt" "$C/$NAME.sv.gfa.gz" "$C/$NAME.paf" \
        --reference GRCh38 --mgSplit --outputFasta "$C/$NAME.sv.gfa.fa.gz"
    cactus_step "$C/chrom-subproblems/chromfile.txt" split \
        cactus-graphmap-split "$C/$NAME.seqfile.txt" "$C/$NAME.sv.gfa.gz" "$C/$NAME.paf" \
        --outDir "$C/chrom-subproblems" --reference GRCh38 --mgSplit
    # largest first, by the size of each chromosome's binned input, so that
    # the long tasks start first and the array ends sooner
    while IFS=$'\t' read -r chrom _; do
        printf '%s\t%s\n' "$(du -sb "$C/chrom-subproblems/$chrom" | cut -f1)" "$chrom"
    done < "$C/chrom-subproblems/chromfile.txt" | sort -k1,1nr | cut -f2 > "$C/chroms.txt.part"
    mv "$C/chroms.txt.part" "$C/chroms.txt"
    log "bin done: $(wc -l < "$C/chroms.txt") chromosomes: $(paste -sd' ' "$C/chroms.txt")"
    ;;

chrom)
    [ -n "$TASK" ] || { echo "$SCRIPT: no chromosome index (argument 5 or SLURM_ARRAY_TASK_ID)" >&2; exit 2; }
    [ -s "$C/chroms.txt" ] || { echo "$SCRIPT: $C/chroms.txt missing: run the bin stage first" >&2; exit 1; }
    chrom=$(awk -v i="$TASK" 'NR == i + 1' "$C/chroms.txt")
    if [ -z "$chrom" ]; then
        log "task $TASK: only $(wc -l < "$C/chroms.txt") chromosomes; nothing to do"
        exit 0
    fi
    INPUT_DIRS=""
    D=$C/chroms/$chrom
    mkdir -p "$D"
    awk -v c="$chrom" -F'\t' '$1 == c' "$C/chrom-subproblems/chromfile.txt" > "$D/chromfile.txt"
    # the construction and the consolidation get this task's whole allocation:
    # Cactus would otherwise size them from its own estimates, which can exceed
    # what the task has, and Toil then refuses to run them
    cactus_step "$D/minigraph/chromfile.mg.txt" "minigraph-$chrom" \
        cactus-minigraph "$D/chromfile.txt" "$D/minigraph" --batch --reference GRCh38 \
        --mgCores "$THREADS" --mgMemory "$MEM"
    cactus_step "$D/graphmap/chromfile.gm.txt" "graphmap-$chrom" \
        cactus-graphmap "$D/minigraph/chromfile.mg.txt" "$D/graphmap" --batch --reference GRCh38
    cactus_step "$D/align/$chrom.hal" "align-$chrom" \
        cactus-align "$D/graphmap/chromfile.gm.txt" "$D/align" --batch --pangenome \
        --reference GRCh38 --outVG --consCores "$THREADS" --consMemory "$MEM"
    log "chrom $chrom done"
    ;;

join)
    INPUT_DIRS=""
    [ -s "$C/chroms.txt" ] || { echo "$SCRIPT: $C/chroms.txt missing: run the bin stage first" >&2; exit 1; }
    vgs=() hals=() gfas=() missing=()
    # the order cactus-pangenome joins them in: sorted by chromosome name
    for chrom in $(LC_ALL=C sort "$C/chroms.txt"); do
        D=$C/chroms/$chrom
        # cactus-align names its graph <chrom>.raw.vg; the join takes that name as it is
        if [ ! -s "$D/align/$chrom.raw.vg" ] || [ ! -s "$D/align/$chrom.hal" ]; then missing+=("$chrom"); continue; fi
        vgs+=("$D/align/$chrom.raw.vg"); hals+=("$D/align/$chrom.hal"); gfas+=("$D/minigraph/$chrom.sv.gfa.gz")
    done
    [ ${#missing[@]} -eq 0 ] || { echo "$SCRIPT: no alignment yet for ${missing[*]}: rerun their chrom tasks" >&2; exit 1; }
    cactus_step "$C/$NAME.d2.gfa.gz" join \
        cactus-graphmap-join --vg "${vgs[@]}" --hal "${hals[@]}" --sv-gfa "${gfas[@]}" \
        --outDir "$C" --outName "$NAME" --reference GRCh38 --gfa clip filter \
        --inputContigSizes "$C/$NAME.input-contig-sizes.tsv.gz"
    [ -f "$C/$NAME.WARNING" ] && { log "Cactus left a warning:"; cat "$C/$NAME.WARNING"; }
    log "join done"
    ;;

index)
    preflight
    [ -s "$C/$NAME.gfa.gz" ] && [ -s "$C/$NAME.d2.gfa.gz" ] \
        || { echo "$SCRIPT: no joined GFAs in $C: run the join stage first" >&2; exit 1; }
    write_build_info "staged over Slurm (build-staged.sh: bin, chrom array, join, index)"
    rc=0
    run_index_release || rc=$?
    log "done: $OUT/release (exit $rc)"
    exit $rc
    ;;

*)
    echo "$SCRIPT: unknown stage '$STAGE' (bin, chrom, join, index)" >&2
    exit 2
    ;;
esac
