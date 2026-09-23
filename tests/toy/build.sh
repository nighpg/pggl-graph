#!/usr/bin/env bash
#
# Rebuilds tests/toy/expected/ -- a complete, validated release, small enough
# to check in -- from the assemblies in tests/toy/input/.
#
#   1. Minigraph-Cactus, all-in-one (cactus-pangenome --mgSplit) in the Cactus
#      image. This is the reference run that the staged pipeline (sbatch/,
#      Workflows/) has to reproduce.
#   2. scripts/index-release.sh in the per-sample vg image: GBZ from the GFAs,
#      indexes, reference, manifest, validation.
#
# Usage: tests/toy/build.sh <cactus.sif> <vg.sif> [workdir]
#   THREADS (default 8). The workdir (default: a new temporary directory) keeps
#   the Cactus outputs and logs.
#   TOY_MODE=update (default) replaces expected/ with the new release.
#   TOY_MODE=check leaves expected/ alone and compares the new release with
#   it: every file that builds reproducibly must be byte-identical (see
#   README.md), and validation must pass. This is the smoke test for a new
#   host, the air-gapped one included.
#   Regenerate the inputs first with make_inputs.py if the generator changed.
set -euo pipefail

CACTUS_SIF=$(readlink -f "${1:?usage: build.sh <cactus.sif> <vg.sif> [workdir]}")
VG_SIF=$(readlink -f "${2:?usage: build.sh <cactus.sif> <vg.sif> [workdir]}")
WORK=${3:-$(mktemp -d)}
THREADS=${THREADS:-8}
TOY=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO=$(cd "$TOY/../.." && pwd)
AP=${APPTAINER:-$(command -v apptainer || ls -d /opt/pkg/apptainer/*/bin/apptainer 2>/dev/null | sort -V | tail -1)}
mkdir -p "$WORK"
WORK=$(readlink -f "$WORK")
rm -rf "$WORK/js" "$WORK/mc" "$WORK/release"
mkdir -p "$WORK/toilwork"

echo "== 1. cactus-pangenome ($(date -Is))"
awk -v d="$TOY/input" '{print $1 "\t" d "/" $2}' "$TOY/input/seqfile.txt" > "$WORK/seqfile.txt"
# The options below are recorded in the manifest as build.options; keep both
# in step.
"$AP" exec --cleanenv --bind "$TOY,$WORK" "$CACTUS_SIF" \
    cactus-pangenome "$WORK/js" "$WORK/seqfile.txt" \
    --outDir "$WORK/mc" --outName toy --reference GRCh38 --mgSplit \
    --gfa clip filter --binariesMode local --maxCores "$THREADS" \
    --workDir "$WORK/toilwork" --logFile "$WORK/cactus.log" > "$WORK/cactus.stdout" 2>&1

versions=$("$AP" exec --cleanenv "$CACTUS_SIF" bash -c \
    'pip list 2>/dev/null | awk "/^(Cactus|toil) /{print \$2}"; vg version | head -1 | awk "{print \$3}"')
read -r cactus_v toil_v cactus_vg <<< "$(echo $versions)"
python3 - "$WORK/build-info.json" "$cactus_v" "$toil_v" "$cactus_vg" \
    "$(basename "$CACTUS_SIF")" "$(sha256sum "$CACTUS_SIF" | cut -d' ' -f1)" <<'EOF'
import datetime, json, sys
out, cv, tv, vg, sif, sha = sys.argv[1:]
json.dump({
    "method": "minigraph-cactus",
    "date": datetime.date.today().isoformat(),
    "cactus_version": cv,
    "toil_version": tv,
    "cactus_image": {"ref": "docker://quay.io/comparative-genomics-toolkit/cactus:v" + cv,
                     "file": sif, "sha256": sha},
    "cactus_internal_vg": vg,
    "reference_order": ["GRCh38"],
    "reference_order_source": "recorded",
    "samples": 5,
    "haplotypes": 8,
    "options": {"reference": ["GRCh38"], "mgSplit": True, "clip": 10000, "filter": 2,
                "gfa": ["clip", "filter"]},
    "note": "tests/toy: synthetic assemblies from make_inputs.py, all-in-one cactus-pangenome",
}, open(out, "w"), indent=2)
EOF
cp "$TOY/input/seqfile.txt" "$WORK/toy.seqfile.txt"

echo "== 2. index-release.sh ($(date -Is))"
mkdir -p "$WORK/release"
cp "$WORK/toy.seqfile.txt" "$WORK/release/"
rev=$(git -C "$REPO" rev-parse --short HEAD 2>/dev/null || echo unknown)
git -C "$REPO" diff --quiet HEAD 2>/dev/null || rev="$rev-dirty"
rc=0
"$AP" exec --cleanenv --bind "$REPO,$WORK" \
    --env SITE=toy,SITE_ROOT=.,RELEASE_LABEL=toy,PGGL_GRAPH_REV="$rev",INDEX_IMAGE_REF="$(basename "$VG_SIF")",INDEX_IMAGE_SHA256="$(sha256sum "$VG_SIF" | cut -d' ' -f1)" \
    "$VG_SIF" \
    bash "$REPO/scripts/index-release.sh" toy "$WORK/release" \
        "$WORK/mc/toy.gfa.gz" "$WORK/mc/toy.d2.gfa.gz" "$TOY/input/GRCh38.fa.gz" \
        "$WORK/build-info.json" "$THREADS" || rc=$?

if [ "${TOY_MODE:-update}" = check ]; then
    echo "== 3. compare with expected/ ($(date -Is))"
    # the distance indexes and the minimizer index are not deterministic
    # across threads; everything else must come out byte for byte
    diffs=0
    for f in "$TOY"/expected/toy.*; do
        b=$(basename "$f")
        case $b in *.dist|*.min) continue ;; esac
        if cmp -s "$f" "$WORK/release/$b"; then
            echo "same  $b"
        else
            echo "DIFF  $b"; diffs=$((diffs + 1))
        fi
    done
    echo "validation: exit $rc; differing files: $diffs"
    echo "workdir: $WORK"
    [ "$rc" -eq 0 ] && [ "$diffs" -eq 0 ] && exit 0
    exit 3
fi

echo "== 3. expected/ ($(date -Is))"
rm -rf "$TOY/expected"
mkdir -p "$TOY/expected"
cp "$WORK"/release/toy.* "$WORK/release/graph.manifest.json" "$TOY/expected/"
cp "$WORK/release/validation/validation.log" "$TOY/expected/"
du -sh "$TOY/expected"
echo "workdir: $WORK"
exit $rc
