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
#   CACTUS_EXTRA  extra options for every Cactus command of the stage, except
#                 --refContigs and --refContigsFile, which only
#                 cactus-graphmap-split takes and so only it is given: a pilot
#                 on one chromosome is CACTUS_EXTRA='--refContigs chr21', as
#                 with build-release.sh
#   MAP_SHARDS    bin stage: run cactus-graphmap as this many parts at once
#                 (default 1). One Toil maps only about RAM / (72 x assembly
#                 size) assemblies at a time -- 7 on a 1.5 TB node -- while
#                 minigraph uses a quarter of that; see map_parts below
#   CHROM_UNTIL   chrom stage: stop after this step, minigraph or graphmap
#                 (default: run through align). Construction and graphmap
#                 take days on a few cores and ~10 GB; align takes hundreds of
#                 GB (chr13, 738 haplotypes: 191 GiB). Run the task with
#                 CHROM_UNTIL=graphmap on a small allocation, then again
#                 without it on a big one: the finished steps are skipped
#
# Every Cactus step runs Toil on this node only, with its own job store under
# WORKROOT, and is skipped when its output exists. A step whose job store was
# left behind -- killed at its time limit, cancelled, failed -- is resumed from
# it with Toil's --restart, on any node: the Toil jobs that finished are kept
# (for a chromosome's construction, every finished batch of 50 haplotypes).
# CACTUS_FRESH=1 discards the job store and starts the step over instead.
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

# CACTUS_EXTRA split in two: the reference-contig subset goes to
# cactus-graphmap-split alone (cactus-minigraph and the rest refuse it; the
# chromosomes it leaves out are never binned, so no later step sees them)
EXTRA=() SPLIT_EXTRA=()
read -ra words <<< "${CACTUS_EXTRA:-}"
i=0
while [ "$i" -lt "${#words[@]}" ]; do
    w=${words[$i]}
    case $w in
        --refContigs=*|--refContigsFile=*) SPLIT_EXTRA+=("$w") ;;
        --refContigs)
            SPLIT_EXTRA+=("$w")
            while [ $((i + 1)) -lt "${#words[@]}" ] && [[ ${words[$((i + 1))]} != -* ]]; do
                i=$((i + 1)); SPLIT_EXTRA+=("${words[$i]}")
            done ;;
        --refContigsFile)
            SPLIT_EXTRA+=("$w")
            if [ $((i + 1)) -lt "${#words[@]}" ]; then i=$((i + 1)); SPLIT_EXTRA+=("${words[$i]}"); fi ;;
        *) EXTRA+=("$w") ;;
    esac
    i=$((i + 1))
done

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
    local js=$WORKROOT/js/$step restart=()
    # a job store whose workflow had started (Toil wrote its root job) is
    # resumed; anything less is a start that never got going
    if [ -s "$js/shared/rootJobStoreID" ] && [ "${CACTUS_FRESH:-0}" != 1 ]; then
        restart=(--restart)
    else
        rm -rf "$js"
    fi
    mkdir -p "$WORKROOT/js" "$OUT/logs/$STAGE"
    if [ ${#restart[@]} -gt 0 ]; then
        log "  $step: $1 --restart (resuming the job store left by an earlier run)"
    else
        log "  $step: $1"
    fi
    # TOIL_HISTORY=False: Toil records every workflow in ~/.toil/history.sqlite,
    # one file for all the tasks of the build. SQLite locking fails on Lustre:
    # of 18 chromosome tasks that started in the same second, four died at once
    # with "sqlite3.OperationalError: disk I/O error". Nothing reads the history
    "$AP" exec --cleanenv --env TOIL_HISTORY=False \
        --bind "$(binds "$OUT" "$WORKROOT" "$INPUT_DIRS" "$REPO")" "$CACTUS_SIF" \
        "$1" "$js" "${@:2}" ${restart[@]+"${restart[@]}"} \
        --binariesMode local --maxCores "$THREADS" --maxMemory "$MEM" \
        --workDir "$WORKROOT/toil" --logFile "$OUT/logs/$STAGE/$step.log" ${EXTRA[@]+"${EXTRA[@]}"}
    [ -e "$done" ] || { echo "$SCRIPT: $step finished but $done is missing" >&2; exit 1; }
    rm -rf "$js"
}

# cactus-graphmap as <n> parts running at once on this node, each with its own
# Toil. Cactus reserves 72x an assembly's size for each minigraph job (some
# 210 GB for a human haplotype; minigraph uses about 50) and Toil caps its pool
# at the machine's RAM, so one Toil maps only a handful of assemblies at a
# time. Each part is GRCh38 plus a contiguous run of the other assemblies in
# seqfile order. Every step of the mapping (minigraph per assembly, the
# reference's rgfa2paf lines, the pass that holds reference contigs apart) is
# decided per query contig, so the parts' PAFs together are the whole run's:
# part 1 as it is, then the others without their GRCh38 lines, which part 1
# already has. Only the order of the lines differs, grouped by part.
# map_parts <n>
map_parts() {
    local n=$1 M=$C/map-parts k rc=0 pids=()
    if [ -e "$C/$NAME.paf" ]; then
        log "  graphmap: done already"
        return 0
    fi
    mkdir -p "$M"
    awk -F'\t' -v n="$n" -v d="$M" '
        $1 == "GRCh38" { ref = $0; next }
        NF { line[++m] = $0 }
        END {
            for (k = 1; k <= n; k++) {
                f = d "/part" k ".seqfile.txt"
                print ref > f
                for (i = int((k - 1) * m / n) + 1; i <= int(k * m / n); i++) print line[i] > f
                close(f)
            }
        }' "$C/$NAME.seqfile.txt"
    log "  graphmap: $n parts of $(($(grep -c . "$C/$NAME.seqfile.txt") - 1)) assemblies, $((THREADS / n)) threads each"
    for k in $(seq 1 "$n"); do
        (
            THREADS=$((THREADS / n))
            cactus_step "$M/part$k.paf" "graphmap-part$k" \
                cactus-graphmap "$M/part$k.seqfile.txt" "$C/$NAME.sv.gfa.gz" "$M/part$k.paf" \
                --reference GRCh38 --mgSplit --outputFasta "$M/part$k.sv.gfa.fa.gz"
        ) &
        pids+=("$!")
    done
    for k in "${pids[@]}"; do wait "$k" || rc=1; done
    [ "$rc" -eq 0 ] || { echo "$SCRIPT: a graphmap part failed; see $OUT/logs/$STAGE/graphmap-part*.log" >&2; exit 1; }
    # every part turns the same GFA into the same FASTA
    for k in $(seq 2 "$n"); do
        cmp -s <(gzip -dc "$M/part1.sv.gfa.fa.gz") <(gzip -dc "$M/part$k.sv.gfa.fa.gz") \
            || { echo "$SCRIPT: graphmap parts 1 and $k wrote different graph FASTAs" >&2; exit 1; }
    done
    cp "$M/part1.sv.gfa.fa.gz" "$C/$NAME.sv.gfa.fa.gz"
    cat "$M"/part*.gaf.gz > "$C/$NAME.gaf.gz"
    { cat "$M/part1.paf"
      for k in $(seq 2 "$n"); do awk -F'\t' 'index($1, "id=GRCh38|") != 1' "$M/part$k.paf"; done
    } > "$C/$NAME.paf.part"
    # as cactus-graphmap --outputFasta does to the seqfile it is given
    "$AP" exec --cleanenv --bind "$(binds "$OUT" "$REPO")" "$CACTUS_SIF" python3 -c \
        'import sys; from cactus.refmap.cactus_graphmap import add_genome_to_seqfile; add_genome_to_seqfile(sys.argv[1], "file://" + sys.argv[2], "_MINIGRAPH_")' \
        "$C/$NAME.seqfile.txt" "$C/$NAME.sv.gfa.fa.gz"
    mv "$C/$NAME.paf.part" "$C/$NAME.paf"
    log "  graphmap: $(wc -l < "$C/$NAME.paf") PAF lines from $n parts"
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
    if [ "${MAP_SHARDS:-1}" -gt 1 ]; then
        map_parts "$MAP_SHARDS"
    else
        cactus_step "$C/$NAME.paf" graphmap \
            cactus-graphmap "$C/$NAME.seqfile.txt" "$C/$NAME.sv.gfa.gz" "$C/$NAME.paf" \
            --reference GRCh38 --mgSplit --outputFasta "$C/$NAME.sv.gfa.fa.gz"
    fi
    cactus_step "$C/chrom-subproblems/chromfile.txt" split \
        cactus-graphmap-split "$C/$NAME.seqfile.txt" "$C/$NAME.sv.gfa.gz" "$C/$NAME.paf" \
        --outDir "$C/chrom-subproblems" --reference GRCh38 --mgSplit ${SPLIT_EXTRA[@]+"${SPLIT_EXTRA[@]}"}
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
    case ${CHROM_UNTIL:-align} in
        minigraph|graphmap|align) ;;
        *) echo "$SCRIPT: CHROM_UNTIL=$CHROM_UNTIL: expected minigraph, graphmap or align" >&2; exit 2 ;;
    esac
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
    if [ "${CHROM_UNTIL:-}" = minigraph ]; then
        log "chrom $chrom: stopping after minigraph (CHROM_UNTIL=minigraph)"
        exit 0
    fi
    cactus_step "$D/graphmap/chromfile.gm.txt" "graphmap-$chrom" \
        cactus-graphmap "$D/minigraph/chromfile.mg.txt" "$D/graphmap" --batch --reference GRCh38
    if [ "${CHROM_UNTIL:-}" = graphmap ]; then
        log "chrom $chrom: stopping after graphmap (CHROM_UNTIL=graphmap)"
        exit 0
    fi
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
