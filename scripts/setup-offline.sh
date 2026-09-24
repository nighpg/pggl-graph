#!/usr/bin/env bash
#
# Installs an offline bundle (from scripts/fetch-offline-bundle.sh) on the
# air-gapped build site. Needs no network.
#
#   bash offline-bundle/setup-offline.sh --bundle offline-bundle --dest <dir> [--verify]
#
#   1. checks SHA256SUMS: transfer damage is the most common failure
#   2. puts the repository at <dest>/pggl-graph (git clone of the bundle, or the
#      tarball when git is missing); an existing checkout is left alone
#   3. copies the images into <dest>/pggl-graph/ and the reference into
#      <dest>/reference/
#   4. writes <dest>/pggl-graph/offline.env: CACTUS_SIF, VG_SIF, GRCH38_PRIMARY,
#      for the build scripts to source
#   5. with --verify: builds the toy release and compares it with the checked-in
#      one (tests/toy/build.sh, TOY_MODE=check). Run it on a compute node, e.g.
#        srun -p compute001-006 -c 16 --mem 32G bash .../setup-offline.sh ... --verify
#      It takes a few minutes; the workdir defaults to /scratch/$USER when
#      /scratch exists.
set -euo pipefail

BUNDLE=""
DEST=""
VERIFY=0
THREADS=${THREADS:-$(nproc)}  # the CPUs this job was given; srun -c sets them
WORKDIR=""

usage() { awk 'NR>1 && /^#/ { sub(/^# ?/, ""); print; next } NR>1 { exit }' "${BASH_SOURCE[0]}"
    echo; echo "Options: --bundle DIR --dest DIR [--verify] [--threads N] [--workdir DIR]"; }

while [ $# -gt 0 ]; do
    case $1 in
        --bundle) BUNDLE=$2; shift 2 ;;
        --dest) DEST=$2; shift 2 ;;
        --verify) VERIFY=1; shift ;;
        --threads) THREADS=$2; shift 2 ;;
        --workdir) WORKDIR=$2; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) echo "unknown option: $1" >&2; usage >&2; exit 2 ;;
    esac
done
[ -n "$BUNDLE" ] && [ -n "$DEST" ] || { usage >&2; exit 2; }
BUNDLE=$(cd "$BUNDLE" && pwd)
mkdir -p "$DEST"
DEST=$(cd "$DEST" && pwd)
log() { echo "[$(date +%H:%M:%S)] $*"; }

log "1. checksums"
( cd "$BUNDLE" && sha256sum --quiet -c SHA256SUMS ) \
    || { echo "setup-offline.sh: the bundle is damaged; copy it again" >&2; exit 1; }
cat "$BUNDLE/BUNDLE_INFO.txt"

log "2. repository"
R=$DEST/pggl-graph
if [ -e "$R" ]; then
    log "   $R exists; leaving it as it is"
elif command -v git >/dev/null; then
    git clone -q "$BUNDLE/repo/pggl-graph.bundle" "$R"
    git -C "$R" remote set-url origin https://github.com/nighpg/pggl-graph.git
else
    tar -C "$DEST" -xzf "$BUNDLE"/repo/pggl-graph-*.tar.gz
fi

log "3. images and reference"
cp -f "$BUNDLE"/sif/*.sif "$R/"
cactus_sif=$(ls "$R"/cactus_v*.sif | sort -V | tail -1)
vg_sif=""
for f in "$R"/*.sif; do
    case $f in */cactus_v*) ;; *) vg_sif=$f; break ;; esac
done
[ -n "$vg_sif" ] || { echo "setup-offline.sh: no vg SIF in the bundle" >&2; exit 1; }
mkdir -p "$DEST/reference"
if ls "$BUNDLE"/reference/* >/dev/null 2>&1; then
    cp -f "$BUNDLE"/reference/* "$DEST/reference/"
fi

log "4. offline.env"
bundle_rev=$(awk '$1 == "repository" {print $2}' "$BUNDLE/BUNDLE_INFO.txt")
cat > "$R/offline.env" <<EOF
# written by setup-offline.sh on $(date -Is); source it before a build
CACTUS_SIF=$cactus_sif
VG_SIF=$vg_sif
GRCH38_PRIMARY=$DEST/reference/GRCh38.primary.fa
# the bundle's commit, recorded in manifests where git is not available
PGGL_GRAPH_REV=$bundle_rev
EOF
cat "$R/offline.env"

AP=${APPTAINER:-$(command -v apptainer || command -v singularity || ls -d /opt/pkg/apptainer/*/bin/apptainer 2>/dev/null | sort -V | tail -1)}
[ -x "$AP" ] || { echo "setup-offline.sh: apptainer not found; set APPTAINER" >&2; exit 1; }
"$AP" exec "$cactus_sif" cactus-pangenome --help > /dev/null
vg_out=$("$AP" exec "$vg_sif" vg version)
echo "${vg_out%%$'\n'*}"

if [ "$VERIFY" -eq 1 ]; then
    if [ -z "$WORKDIR" ]; then
        if [ -d /scratch ]; then WORKDIR=/scratch/$USER/pggl-graph-toy; else WORKDIR=$(mktemp -d); fi
    fi
    log "5. toy build in $WORKDIR (TOY_MODE=check, $THREADS threads)"
    [ "$THREADS" -ge 4 ] || log "   only $THREADS CPU(s): this works but is slow; use srun -c 16"
    rc=0
    APPTAINER=$AP TOY_MODE=check THREADS=$THREADS \
        bash "$R/tests/toy/build.sh" "$cactus_sif" "$vg_sif" "$WORKDIR" || rc=$?
    if [ "$rc" -eq 0 ]; then
        log "verified: the toy release builds here and matches the checked-in one"
    else
        log "VERIFY FAILED (exit $rc); the log and outputs are in $WORKDIR"
        exit "$rc"
    fi
fi
log "done: $R"
