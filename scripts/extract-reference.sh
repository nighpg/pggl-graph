#!/usr/bin/env bash
#
# Extracts the reference from the graph itself, rather than trusting an
# external FASTA to agree with it, and writes pggl-workflow's ref (+ .fai,
# .dict) and ref_paths (the PanSN .dict). With the source FASTA given, every
# contig is checked to be md5-identical to it, which is what keeps CRAMs
# encoded against the source decodable (see reference_files.py).
#
# Usage: extract-reference.sh <gbz> <ref_sample> <path_prefix> <outprefix> [source.fa[.gz]]
set -euo pipefail

GBZ=${1:?usage: extract-reference.sh <gbz> <ref_sample> <path_prefix> <outprefix> [source.fa]}
SAMPLE=${2:?}
PREFIX=${3:?}
OUT=${4:?}
SOURCE=${5:-}
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

TMP=$(mktemp "${TMPDIR:-$(dirname "$OUT")}/graph-ref.XXXXXX.fa")
trap 'rm -f "$TMP"' EXIT

vg paths -x "$GBZ" -S "$SAMPLE" -F > "$TMP"
python3 "$HERE/reference_files.py" "$TMP" "$PREFIX" "$OUT" ${SOURCE:+"$SOURCE"}
