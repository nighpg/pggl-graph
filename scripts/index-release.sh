#!/usr/bin/env bash
#
# Stages [D] and [E] on one host: turns the clip and filter GFAs from
# cactus-graphmap-join into a release directory, with every file made by the vg
# on PATH (the per-sample vg), then writes and validates its manifest.
#
#   clip:   gbz, dist, ri, hapl, snarls   haplotype sampling, call_sv
#   filter: gbz, dist, min, zipcodes, snarls   giraffe
#   ref:    fa, fa.fai, dict, pansn.dict   extracted from the graph and
#           checked md5-identical to the source FASTA
#
# The production sbatch jobs run the same scripts one per job; this is for the
# toy and for builds small enough for one node.
#
# Usage: index-release.sh <name> <release_dir> <clip.gfa[.gz]> <filter.gfa[.gz]>
#                         <source GRCh38.fa[.gz]> <build-info.json> [threads]
# Environment:
#   RELEASE_LABEL   release label for the manifest (default: today's date)
#   SITE, SITE_ROOT manifest site name and its release root (default: "local"
#                   and the release directory)
#   TARGET_MEM      vg autoindex -M
set -euo pipefail

NAME=${1:?usage: index-release.sh <name> <release_dir> <clip.gfa> <filter.gfa> <source.fa> <build-info.json> [threads]}
R=${2:?}
CLIP_GFA=${3:?}
FILTER_GFA=${4:?}
SOURCE_FA=${5:?}
BUILD_INFO=${6:?}
THREADS=${7:-8}
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
mkdir -p "$R"
# a private subdirectory, so that removing it never touches a shared TMPDIR
TMPDIR=$(mktemp -d "${TMPDIR:-$R}/index-release.XXXXXX")
export TMPDIR
trap 'rm -rf "$TMPDIR"' EXIT
P=$R/$NAME

step() { echo; echo "== $* ($(date -Is))"; }

step "GBZ from the GFAs"
bash "$HERE/gfa-to-gbz.sh" "$CLIP_GFA" "$P.clip.gbz" "$THREADS" GRCh38
bash "$HERE/gfa-to-gbz.sh" "$FILTER_GFA" "$P.filter.gbz" "$THREADS" GRCh38

step "reference from the graph"
bash "$HERE/extract-reference.sh" "$P.clip.gbz" GRCh38 'GRCh38#0#' "$P.ref" "$SOURCE_FA"

step "filter graph: giraffe indexes"
bash "$HERE/vg-autoindex.sh" "$P.filter.gbz" "$P.filter" "$THREADS" ${TARGET_MEM:+"$TARGET_MEM"}

step "clip graph: haplotype sampling indexes"
bash "$HERE/vg-haplotype-index.sh" "$P.clip.gbz" "$P.clip" "$THREADS"

step "snarls"
bash "$HERE/vg-snarls.sh" "$P.clip.gbz" "$P.clip" "$THREADS" true
bash "$HERE/vg-snarls.sh" "$P.filter.gbz" "$P.filter" "$THREADS" true

step "manifest"
python3 "$HERE/write-manifest.py" --release-dir "$R" --name "$NAME" \
    --release "${RELEASE_LABEL:-$(date +%Y-%m-%d)}" \
    --site "${SITE:-local}" ${SITE_ROOT:+--site-root "$SITE_ROOT"} \
    --build-info "$BUILD_INFO" --source-fasta "$SOURCE_FA" \
    ${INDEX_IMAGE_REF:+--index-image-ref "$INDEX_IMAGE_REF"} \
    ${INDEX_IMAGE_SHA256:+--index-image-sha256 "$INDEX_IMAGE_SHA256"} \
    -o "$R/graph.manifest.json"

step "validate"
rc=0
bash "$HERE/validate-graph.sh" "$R/graph.manifest.json" "${SITE:-local}" "$R/validation" || rc=$?
python3 "$HERE/manifest.py" set-validation "$R/graph.manifest.json" "$R/validation/validation.json"
exit $rc
