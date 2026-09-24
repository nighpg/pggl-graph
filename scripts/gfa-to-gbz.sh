#!/usr/bin/env bash
#
# Rebuilds a Cactus graph as a GBZ with the vg on PATH, which must be the vg of
# the per-sample workflows. The GBZ Cactus writes itself comes from its own vg
# (v1.76 in Cactus v3.3.0) and is format v2, which vg 1.70 refuses
# ("GBZ: Expected v1, got v2"); the GFA is the version-neutral hand-over.
#
# Two things vg 1.70 needs that the Cactus GFA does not give it
# (tests/compat/vg-gbz-compat.sh):
#   - a single H line: vg 1.76 adds "H NM:Z:<name>", and 1.70 stops with
#     "GFAFile: duplicate header". Every H line after the first is dropped; the
#     first one carries RS:Z:, which becomes the reference_samples tag.
#   - an uncompressed file: 1.70 fails on .gfa.gz without saying why.
#
# Usage: gfa-to-gbz.sh <in.gfa[.gz]> <out.gbz> <threads> [expected reference sample]
#   The decompressed copy goes to $TMPDIR (default: next to the output) and is
#   removed afterwards; on a whole-genome graph it is tens of GB.
set -euo pipefail

IN=${1:?usage: gfa-to-gbz.sh <in.gfa[.gz]> <out.gbz> <threads> [ref sample]}
OUT=${2:?usage: gfa-to-gbz.sh <in.gfa[.gz]> <out.gbz> <threads> [ref sample]}
THREADS=${3:-8}
REF_SAMPLE=${4:-}

TMP=$(mktemp -d "${TMPDIR:-$(dirname "$OUT")}/gfa-to-gbz.XXXXXX")
trap 'rm -rf "$TMP"' EXIT

case $IN in
    *.gz) reader=(zcat "$IN") ;;
    *)    reader=(cat "$IN") ;;
esac
"${reader[@]}" | awk '!/^H/ || !seen++' > "$TMP/graph.gfa"

[ "$(head -c 1 "$TMP/graph.gfa")" = H ] \
    || { echo "gfa-to-gbz.sh: $IN has no header line" >&2; exit 1; }

vg gbwt -G "$TMP/graph.gfa" --gbz-format -g "$OUT" --num-threads "$THREADS"

# Read vg's whole output before testing it: `vg describe | grep -q` under
# pipefail fails at random, when grep stops reading and vg dies of SIGPIPE.
desc=$(vg describe "$OUT")
grep -q '^  Version 1$' <<< "$desc" \
    || { echo "gfa-to-gbz.sh: $OUT is not a GBZ v1" >&2; printf '%s\n' "$desc" >&2; exit 1; }
if [ -n "$REF_SAMPLE" ]; then
    rs=$(vg gbwt -Z "$OUT" --tags | awk -F'\t' '$1 == "reference_samples" {print $2}')
    [[ " $rs " == *" $REF_SAMPLE "* ]] \
        || { echo "gfa-to-gbz.sh: reference_samples is '$rs', no $REF_SAMPLE" >&2; exit 1; }
fi
