#!/usr/bin/env bash
#
# Checks a release against what pggl-workflow relies on, using the vg that the
# per-sample side runs. Every check runs even after one fails, so a single pass
# gives the full picture.
#
#   1  paths     vg paths -S <ref> lists exactly <contigs> paths, none with "["
#   2  lengths   every contig is one whole path with the .fai length
#   3  tags      the GBWT reference_samples tag contains <ref>
#   4  readable  every index of the graph is identified by this vg with a
#                header it understands (a GBZ v2 or .hapl v4 is not); the .hapl
#                is also loaded against its graph, the snarls are streamed
#   5  surject   reads simulated from a reference path, mapped with giraffe and
#                surjected, give @SQ = <prefix><contig> with the .fai length
#                  5a with the PanSN .dict as ref_paths (what the pipeline passes)
#                  5b with a plain list of the graph's reference path names;
#                     only whole paths make this work, so it catches a graph
#                     that silently needs the .dict
#
# Checks 1-4 run for every graph in the manifest, check 5 for the giraffe one.
#
# Usage: validate-graph.sh <manifest> <site> <outdir>
#   Writes <outdir>/validation.json (the manifest's validation block, see
#   manifest.py set-validation), validation.log and the intermediates.
#
# Environment:
#   THREADS          threads for giraffe / surject / snarls (default 8)
#   SIM_PAIRS        read pairs to simulate for check 5 (default 1000)
#   PGGL_GRAPH_REV   pggl-graph revision to record (default: git, if available)
#
# Exit: 0 all checks pass, 3 a check failed (as in pggl-workflow's
# vg-call-sv.sh guard), 1 the checks could not be run.
set -uo pipefail

MANIFEST=${1:?usage: validate-graph.sh <manifest> <site> <outdir>}
SITE=${2:?usage: validate-graph.sh <manifest> <site> <outdir>}
OUT=${3:?usage: validate-graph.sh <manifest> <site> <outdir>}
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
THREADS=${THREADS:-8}
SIM_PAIRS=${SIM_PAIRS:-1000}
EVAL="python3 $HERE/validate_graph_eval.py"

command -v vg >/dev/null || { echo "validate-graph.sh: vg not on PATH" >&2; exit 1; }
mkdir -p "$OUT"
LOG=$OUT/validation.log
RES=$OUT/checks.tsv
: > "$LOG"
: > "$RES"

RESOLVED=$(python3 "$HERE/manifest.py" resolve "$MANIFEST" --site "$SITE") || exit 1
eval "$RESOLVED"

VG_VERSION=$(vg version | awk 'NR == 1 {print $3}')
REV=${PGGL_GRAPH_REV:-$(git -C "$HERE" rev-parse --short HEAD 2>/dev/null || echo unknown)}
log() { echo "$*" | tee -a "$LOG"; }
record() {  # record <id> <name> <status> <detail>
    printf '%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" >> "$RES"
    log "$(printf '%-5s %-9s %-4s %s' "$1" "$2" "$3" "$4")"
}
judge() {  # judge <id> <name> <evaluator output "status<TAB>detail">
    record "$1" "$2" "${3%%$'\t'*}" "${3#*$'\t'}"
}

log "validate-graph.sh ${NAME} ${RELEASE} (site ${SITE}) with vg ${VG_VERSION}, pggl-graph ${REV}"
log "manifest index_builder.vg_version: ${INDEX_VG}"
[ "$VG_VERSION" = "$INDEX_VG" ] || log "WARNING: validating with vg ${VG_VERSION}, not the manifest's ${INDEX_VG}"
log ""

$EVAL expected "$PANSN_DICT" "$REF_PREFIX" "${FAI:--}" > "$OUT/expected.tsv" || exit 1
n_exp=$(wc -l < "$OUT/expected.tsv")
[ "$n_exp" -eq "$REF_CONTIGS" ] || { echo "validate-graph.sh: .dict has ${n_exp} contigs, manifest says ${REF_CONTIGS}" >&2; exit 1; }

var() { local v="G_$1_$2"; echo "${!v:-}"; }

for g in $GRAPHS; do
    W=$OUT/$g
    mkdir -p "$W"
    gbz=$(var "$g" gbz)

    # 1 + 2: one load of the path list gives both names and lengths
    if vg paths -x "$gbz" -S "$REF_SAMPLE" -E > "$W/ref-paths.tsv" 2>> "$LOG"; then
        n=$(wc -l < "$W/ref-paths.tsv")
        nfrag=$(cut -f1 "$W/ref-paths.tsv" | grep -c '\[' || true)
        if [ "$n" -eq "$REF_CONTIGS" ] && [ "$nfrag" -eq 0 ]; then
            record "1/$g" paths pass "${n} ${REF_SAMPLE} paths, no fragment names"
        else
            record "1/$g" paths fail "${n} ${REF_SAMPLE} paths (expected ${REF_CONTIGS}), ${nfrag} with fragment names such as $(cut -f1 "$W/ref-paths.tsv" | grep -m1 '\[' || echo -)"
        fi
        judge "2/$g" lengths "$($EVAL lengths "$OUT/expected.tsv" "$W/ref-paths.tsv" "$REF_PREFIX")"
    else
        record "1/$g" paths fail "vg paths could not read ${gbz}"
        record "2/$g" lengths fail "no path list (see check 1)"
    fi

    # 3
    if vg gbwt -Z "$gbz" --tags > "$W/tags.tsv" 2>> "$LOG"; then
        rs=$(awk -F'\t' '$1 == "reference_samples" {print $2}' "$W/tags.tsv")
        if [[ " $rs " == *" $REF_SAMPLE "* ]]; then
            record "3/$g" tags pass "reference_samples = ${rs}"
        else
            record "3/$g" tags fail "reference_samples = '${rs}', no ${REF_SAMPLE}"
        fi
    else
        record "3/$g" tags fail "vg gbwt could not read ${gbz}"
    fi

    # 4: what this vg makes of each file's header, then real loads where cheap
    declare -A want=( [gbz]=GBZ [dist]=SnarlDistanceIndex [min]=MinimizerIndex
                      [zipcodes]=ZipCodeCollection [ri]=R-index [hapl]=Haplotypes )
    verdicts=()
    fails=0
    for k in gbz dist min zipcodes ri hapl snarls; do
        f=$(var "$g" "$k")
        [ -n "$f" ] || continue
        if [ "$k" = snarls ]; then
            # vg describe does not identify snarls; stream them instead
            if nsn=$(vg view -R "$f" 2>> "$LOG" | wc -l) && [ "$nsn" -gt 0 ]; then
                verdicts+=( "snarls ok (${nsn} records)" )
            else
                verdicts+=( "snarls UNREADABLE" ); fails=$((fails + 1))
            fi
            continue
        fi
        vg describe "$f" > "$W/describe.$k.txt" 2>> "$LOG"
        type=$(sed -n 's/^File .* is \(.*\)$/\1/p' "$W/describe.$k.txt" | head -1)
        ver=$(grep -m1 -oP '^\s+Version \K[0-9]+' "$W/describe.$k.txt" || true)
        # These formats print a header with a version when this vg can read them
        needs_ver=0
        case $k in gbz|min|ri|hapl) needs_ver=1 ;; esac
        if [ "$type" != "${want[$k]}" ]; then
            verdicts+=( "${k} is '${type:-unidentified}', not ${want[$k]}" ); fails=$((fails + 1))
        elif [ "$needs_ver" -eq 1 ] && [ -z "$ver" ]; then
            verdicts+=( "${k} ${type} with a header this vg cannot parse" ); fails=$((fails + 1))
        else
            verdicts+=( "${k} ${type}${ver:+ v$ver}" )
        fi
    done
    hapl=$(var "$g" hapl)
    if [ -n "$hapl" ]; then
        if vg haplotypes -i "$hapl" --statistics "$REF_SAMPLE" "$gbz" > "$W/hapl-stats.tsv" 2> "$W/hapl-stats.err"; then
            verdicts+=( "hapl loads against the gbz" )
        elif grep -q "found [0-9]* paths for sample" "$W/hapl-stats.err"; then
            # the statistics need one path per contig: a fragmented reference,
            # which checks 1-2 already report, not an unreadable file
            verdicts+=( "hapl loads, but its per-contig statistics fail on the fragmented ${REF_SAMPLE}" )
        else
            verdicts+=( "hapl does NOT load against the gbz: $(grep -m1 -i error "$W/hapl-stats.err")" ); fails=$((fails + 1))
        fi
        cat "$W/hapl-stats.err" >> "$LOG"
    fi
    detail=$(IFS=';'; echo "${verdicts[*]}" | sed 's/;/; /g')
    record "4/$g" readable "$([ "$fails" -eq 0 ] && echo pass || echo fail)" "$detail"
    unset want
done

# 5: only the giraffe graph has a giraffe index set
g=$GIRAFFE_GRAPH
if [ -n "$g" ]; then
    W=$OUT/$g
    gbz=$(var "$g" gbz)
    # simulate from chr20 when there is one: mid-sized, and present in every
    # human graph; otherwise from the first reference path
    src=$(awk -F'\t' '$1 ~ /#chr20(\[|$)/ {print $1; exit}' "$W/ref-paths.tsv" 2>/dev/null)
    [ -n "$src" ] || src=$(awk -F'\t' 'NR == 1 {print $1}' "$W/ref-paths.tsv" 2>/dev/null)
    cut -f1 "$W/ref-paths.tsv" > "$W/plain-ref-paths.txt" 2>/dev/null
    if [ -z "$src" ]; then
        record 5a surject fail "no reference path to simulate from (see check 1)"
        record 5b surject fail "no reference path to simulate from (see check 1)"
    elif ! vg sim -x "$gbz" -P "$src" -n "$SIM_PAIRS" -l 150 -p 400 -v 50 \
            -e 0.005 -i 0.0005 -s 42 -a > "$W/sim.gam" 2>> "$LOG"; then
        record 5a surject fail "vg sim failed on ${src}"
        record 5b surject fail "vg sim failed on ${src}"
    elif ! vg giraffe -Z "$gbz" -d "$(var "$g" dist)" -m "$(var "$g" min)" \
            -z "$(var "$g" zipcodes)" -G "$W/sim.gam" -i \
            -t "$THREADS" --output-format GAM > "$W/mapped.gam" 2>> "$LOG"; then
        record 5a surject fail "vg giraffe failed (see the log)"
        record 5b surject fail "vg giraffe failed (see the log)"
    else
        log "check 5: ${SIM_PAIRS} pairs simulated from ${src}"
        for v in a b; do
            if [ "$v" = a ]; then rp=$PANSN_DICT; what="PanSN .dict"; else rp=$W/plain-ref-paths.txt; what="plain path list"; fi
            if vg surject -x "$gbz" -s -i -F "$rp" -t "$THREADS" "$W/mapped.gam" > "$W/surject.$v.sam" 2> "$W/surject.$v.err"; then
                r=$($EVAL sam "$OUT/expected.tsv" "$W/surject.$v.sam" "$REF_PREFIX")
                record "5$v" surject "${r%%$'\t'*}" "${what}: ${r#*$'\t'}"
            else
                record "5$v" surject fail "${what}: vg surject failed: $(grep -m1 -i error "$W/surject.$v.err" | sed "s#${rp}#<ref_paths>#")"
            fi
            cat "$W/surject.$v.err" >> "$LOG"
        done
    fi
fi

$EVAL report "$RES" "$VG_VERSION" "scripts/validate-graph.sh @ pggl-graph ${REV}" "$GIRAFFE_GRAPH" \
    > "$OUT/validation.json" || exit 1
status=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["status"])' "$OUT/validation.json")
log ""
# no path in the log: it is kept with the release, and checked in for the toy
log "overall: ${status}"
echo "result: ${OUT}/validation.json"
[ "$status" = pass ] && exit 0 || exit 3
