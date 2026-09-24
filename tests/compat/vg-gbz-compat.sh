#!/usr/bin/env bash
#
# Checks whether a graph written by the vg inside the Cactus image can be read
# by the vg the per-sample workflows use, and whether the GFA route around it
# still works. Re-run this whenever either image changes.
#
# Usage: vg-gbz-compat.sh <cactus.sif> <consumer-vg.sif> [workdir]
#
# Result on 2026-09-23 (cactus v3.3.0 = vg v1.76.1-89, consumer = vg v1.70.0):
#   - vg 1.70 rejects the 1.76 GBZ outright: "GBZ: Expected v1, got v2"
#   - vg 1.70 rejects the 1.76 GFA too: "GFAFile: duplicate header at line 1",
#     because 1.76 writes a second H line (NM:Z:<graph name>)
#   - with the extra H lines dropped and the GFA uncompressed (1.70 fails on
#     .gfa.gz without saying why), 1.70 builds a GBZ that keeps
#     reference_samples, and autoindex / gbwt -r / snarls all run on it
#   - a .snarls file written by 1.76 is still readable by 1.70
set -uo pipefail

CACTUS_SIF=${1:?usage: vg-gbz-compat.sh <cactus.sif> <consumer-vg.sif> [workdir]}
VG_SIF=${2:?usage: vg-gbz-compat.sh <cactus.sif> <consumer-vg.sif> [workdir]}
WORK=${3:-$(mktemp -d)}
for sif in "$CACTUS_SIF" "$VG_SIF"; do
    [ -f "$sif" ] || { echo "vg-gbz-compat.sh: $sif not found" >&2; exit 2; }
done
CACTUS_SIF=$(readlink -f "$CACTUS_SIF")
VG_SIF=$(readlink -f "$VG_SIF")
mkdir -p "$WORK"
cd "$WORK"

new() { apptainer exec "$CACTUS_SIF" "$@"; }
old() { apptainer exec "$VG_SIF" "$@"; }

printf 'H\tVN:Z:1.1\tRS:Z:GRCh38\n' > toy.gfa
cat >> toy.gfa <<'EOF'
S	1	ACGTACGTAC
S	2	G
S	3	T
S	4	CATGCATGCA
L	1	+	2	+	0M
L	1	+	3	+	0M
L	2	+	4	+	0M
L	3	+	4	+	0M
W	GRCh38	0	chr1	0	21	>1>2>4
W	S1	1	ctgA	0	21	>1>3>4
W	S1	2	ctgB	0	21	>1>2>4
EOF

echo "producer: $(new vg version | awk 'NR == 1')"
echo "consumer: $(old vg version | awk 'NR == 1')"

new vg gbwt -G toy.gfa --gbz-format -g new.gbz 2>/dev/null
new vg snarls new.gbz > new.snarls 2>/dev/null
new vg convert -f new.gbz > new.gfa 2>/dev/null

check() {  # check <label> <command...>
    local label=$1; shift
    if "$@" >/dev/null 2>&1; then echo "PASS  $label"; else echo "FAIL  $label"; fi
}

check "consumer reads producer GBZ"         old vg paths -x new.gbz -L
check "consumer reads producer GFA as is"   old vg gbwt -G new.gfa --gbz-format -g asis.gbz
check "consumer reads producer snarls"      old vg view -R new.snarls

# The route around it: drop every H line but the first, keep the GFA plain.
awk '!/^H/ || !seen++' new.gfa > fixed.gfa
check "consumer builds GBZ from fixed GFA"  old vg gbwt -G fixed.gfa --gbz-format -g old.gbz
tags=$(old vg gbwt -Z old.gbz --tags 2>/dev/null)
if grep -qP '^reference_samples\tGRCh38$' <<< "$tags"; then
    echo "PASS  reference_samples survives the GFA route"
else
    echo "FAIL  reference_samples survives the GFA route"
fi
check "consumer autoindex on rebuilt GBZ"   old vg autoindex -p idx -G old.gbz -w giraffe -t 2
check "consumer r-index on rebuilt GBZ"     old vg gbwt -Z old.gbz -r idx.ri
check "consumer snarls on rebuilt GBZ"      old vg snarls -t 1 old.gbz

echo "workdir: $WORK"
