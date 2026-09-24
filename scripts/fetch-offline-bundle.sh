#!/usr/bin/env bash
#
# Collects everything a graph build needs into one directory that can be
# carried to the air-gapped build site. Runs on an ONLINE host; it is the only
# step that may touch the network. The build itself needs none (the toy builds
# under `unshare -rn`).
#
#   scripts/fetch-offline-bundle.sh --vg-sif <per-sample vg SIF> [options]
#
# On the offline host:
#
#   tar xf pggl-graph-offline-bundle-<date>.tar        # when --archive was used
#   bash offline-bundle/setup-offline.sh --bundle offline-bundle --dest <dir> --verify
#
# What ends up in the bundle:
#   sif/        the Cactus image and the per-sample vg image (the vg every index
#               is built with; it must be the image pggl-workflow runs)
#   reference/  GRCh38.primary.fa: the 25 primary contigs of the GRCh38 FASTA,
#               sequences untouched, and their M5 sums
#   repo/       this repository as a git bundle (full history) and as a tarball
#               of HEAD, for hosts without git
#   setup-offline.sh, README-offline.md, BUNDLE_INFO.txt, SHA256SUMS
#
# NOT included: the input assemblies, which are chosen per build. Carry them
# separately (see docs/OFFLINE.md).
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/retry.sh
. "$REPO/scripts/lib/retry.sh"

CACTUS_VERSION=3.3.0
OUTDIR="$REPO/offline-bundle"
VG_SIF=""
CACTUS_SIF=""
GRCH38="ftp://ftp.1000genomes.ebi.ac.uk/vol1/ftp/technical/reference/GRCh38_reference_genome/GRCh38_full_analysis_set_plus_decoy_hla.fa"
WANT_GRCH38=1
WANT_REPO=1
WANT_ARCHIVE=0
SPLIT_SIZE=""

usage() {
    awk 'NR>1 && /^#/ { sub(/^# ?/, ""); print; next } NR>1 { exit }' "${BASH_SOURCE[0]}"
    cat <<'USAGE'

Options:
  -o, --outdir DIR        bundle directory (default ./offline-bundle)
      --vg-sif PATH       the per-sample vg image (default:
                          ../pggl-workflow/deepvariant-opencode-cpu-vg.sif)
      --cactus-sif PATH   an existing Cactus SIF (default: ./cactus_v<version>.sif,
                          pulled from quay.io when absent)
      --cactus-version V  Cactus release to pull (default 3.3.0)
      --grch38 PATH|URL   full GRCh38 FASTA to take the primary contigs from
                          (default: the 1000 Genomes analysis set URL)
      --no-grch38         leave the reference out
      --no-repo           leave the repository out
      --archive           also pack the bundle into one .tar (+ .sha256)
      --split SIZE        split the .tar into parts of SIZE (e.g. 20G); implies --archive
  -h, --help
USAGE
}

while [ $# -gt 0 ]; do
    case $1 in
        -o|--outdir) OUTDIR=$2; shift 2 ;;
        --vg-sif) VG_SIF=$2; shift 2 ;;
        --cactus-sif) CACTUS_SIF=$2; shift 2 ;;
        --cactus-version) CACTUS_VERSION=$2; shift 2 ;;
        --grch38) GRCH38=$2; shift 2 ;;
        --no-grch38) WANT_GRCH38=0; shift ;;
        --no-repo) WANT_REPO=0; shift ;;
        --archive) WANT_ARCHIVE=1; shift ;;
        --split) SPLIT_SIZE=$2; WANT_ARCHIVE=1; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) echo "unknown option: $1" >&2; usage >&2; exit 2 ;;
    esac
done

AP=${APPTAINER:-$(command -v apptainer || command -v singularity || ls -d /opt/pkg/apptainer/*/bin/apptainer 2>/dev/null | sort -V | tail -1)}
[ -x "$AP" ] || { echo "apptainer not found; set APPTAINER" >&2; exit 1; }

: "${VG_SIF:=$REPO/../pggl-workflow/deepvariant-opencode-cpu-vg.sif}"
[ -f "$VG_SIF" ] || { echo "vg image not found: $VG_SIF (use --vg-sif)" >&2; exit 1; }
: "${CACTUS_SIF:=$REPO/cactus_v${CACTUS_VERSION}.sif}"

mkdir -p "$OUTDIR"/{sif,reference,repo}
OUTDIR=$(cd "$OUTDIR" && pwd)
log() { echo "[$(date +%H:%M:%S)] $*"; }

# --- images ---------------------------------------------------------------
if [ ! -f "$CACTUS_SIF" ]; then
    log "pulling Cactus v${CACTUS_VERSION}"
    retry 4 30 "$AP" pull "$CACTUS_SIF" \
        "docker://quay.io/comparative-genomics-toolkit/cactus:v${CACTUS_VERSION}"
fi
got=$("$AP" exec "$CACTUS_SIF" bash -c 'pip list 2>/dev/null | awk "/^Cactus /{print \$2}"')
[ "$got" = "$CACTUS_VERSION" ] \
    || { echo "$CACTUS_SIF holds Cactus '$got', not $CACTUS_VERSION" >&2; exit 1; }
vg_version=$("$AP" exec "$VG_SIF" vg version | awk 'NR == 1 {print $3}')
log "images: Cactus $got ($(basename "$CACTUS_SIF")), vg $vg_version ($(basename "$VG_SIF"))"
cp -f "$CACTUS_SIF" "$OUTDIR/sif/"
cp -f "$VG_SIF" "$OUTDIR/sif/"

# --- reference ------------------------------------------------------------
if [ "$WANT_GRCH38" -eq 1 ]; then
    src=$GRCH38
    case $GRCH38 in
        *://*)
            src="$OUTDIR/reference/$(basename "$GRCH38")"
            if [ ! -f "$src" ]; then
                log "downloading $GRCH38"
                fetch_url "$GRCH38" "$src"
            fi ;;
    esac
    log "GRCh38 primary contigs from $(basename "$src")"
    python3 "$REPO/scripts/grch38-primary.py" "$src" "$OUTDIR/reference/GRCh38.primary.fa" \
        2> "$OUTDIR/reference/GRCh38.primary.m5.tsv"
    printf 'source\t%s\nsource_md5\t%s\nsource_size\t%s\n' \
        "$(basename "$src")" "$(md5sum "$src" | cut -d' ' -f1)" "$(stat -Lc %s "$src")" \
        > "$OUTDIR/reference/SOURCE.tsv"
    # a downloaded full FASTA has served its purpose
    case $GRCH38 in *://*) rm -f "$src" ;; esac
fi

# --- repository -----------------------------------------------------------
rev=unknown
if [ "$WANT_REPO" -eq 1 ]; then
    rev=$(git -C "$REPO" rev-parse --short HEAD)
    git -C "$REPO" diff --quiet HEAD \
        || log "WARNING: uncommitted changes are NOT in the bundle (it holds commit $rev)"
    rm -f "$OUTDIR"/repo/*
    git -C "$REPO" bundle create "$OUTDIR/repo/pggl-graph.bundle" HEAD --branches --tags 2> /dev/null
    git -C "$REPO" archive --format=tar.gz --prefix=pggl-graph/ \
        -o "$OUTDIR/repo/pggl-graph-$rev.tar.gz" HEAD
    log "repository at $rev"
fi
cp -f "$REPO/scripts/setup-offline.sh" "$OUTDIR/"
cp -f "$REPO/docs/OFFLINE.md" "$OUTDIR/README-offline.md"

# --- manifest of the bundle ------------------------------------------------
{
    echo "pggl-graph offline bundle"
    echo "created      $(date -Is) on $(hostname)"
    echo "repository   $rev"
    echo "cactus       $got  $(basename "$CACTUS_SIF")  sha256:$(sha256sum "$CACTUS_SIF" | cut -d' ' -f1)"
    echo "vg           $vg_version  $(basename "$VG_SIF")  sha256:$(sha256sum "$VG_SIF" | cut -d' ' -f1)"
    [ -f "$OUTDIR/reference/SOURCE.tsv" ] && sed 's/^/grch38       /' "$OUTDIR/reference/SOURCE.tsv"
    echo
    du -sh "$OUTDIR"/* | sed 's#'"$OUTDIR"'/##'
} > "$OUTDIR/BUNDLE_INFO.txt"
( cd "$OUTDIR" && find . -type f ! -name SHA256SUMS -printf '%P\n' | sort | xargs sha256sum > SHA256SUMS )
log "bundle ready: $OUTDIR ($(du -sh "$OUTDIR" | cut -f1))"

if [ "$WANT_ARCHIVE" -eq 1 ]; then
    tarball="$(dirname "$OUTDIR")/pggl-graph-offline-bundle-$(date +%Y%m%d).tar"
    tar -C "$(dirname "$OUTDIR")" -cf "$tarball" "$(basename "$OUTDIR")"
    sha256sum "$tarball" | sed 's#  .*/#  #' > "$tarball.sha256"
    if [ -n "$SPLIT_SIZE" ]; then
        split -b "$SPLIT_SIZE" -d "$tarball" "$tarball.part-"
        rm -f "$tarball"
        log "archive split into $(ls "$tarball".part-* | wc -l) parts: $tarball.part-*"
    else
        log "archive: $tarball"
    fi
fi
