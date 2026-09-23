#!/usr/bin/env bash
#
# Haplotype sampling indexes for a graph: the r-index and the haplotype
# information that pggl-workflow's haplotype-sample.cwl takes as `hapl`.
# vg haplotypes needs a distance index of the same graph, so one is built too
# and kept (<prefix>.dist).
#
# The k-mer length is vg's default (29), which is what haplotype-sample.cwl's
# kmer_length defaults to; the two must agree.
#
# Usage: vg-haplotype-index.sh <gbz> <prefix> <threads>
#   Produces <prefix>.dist, <prefix>.ri, <prefix>.hapl
set -euo pipefail

GBZ=${1:?usage: vg-haplotype-index.sh <gbz> <prefix> <threads>}
PREFIX=${2:?usage: vg-haplotype-index.sh <gbz> <prefix> <threads>}
THREADS=${3:-8}

[ -s "${PREFIX}.dist" ] || vg index -t "$THREADS" -j "${PREFIX}.dist" "$GBZ"
vg gbwt -p --num-threads "$THREADS" -r "${PREFIX}.ri" -Z "$GBZ"
vg haplotypes -v 1 -t "$THREADS" -d "${PREFIX}.dist" -r "${PREFIX}.ri" \
    -H "${PREFIX}.hapl" "$GBZ"

for f in dist ri hapl; do
    [ -s "${PREFIX}.${f}" ] || { echo "vg-haplotype-index.sh: ${PREFIX}.${f} missing" >&2; exit 1; }
done
