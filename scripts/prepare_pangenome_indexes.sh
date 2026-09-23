#!/usr/bin/env bash
#
# COPY -- the master is nighpg/pggl-workflow scripts/prepare_pangenome_indexes.sh (copied at 6738d0e).
# Change it there first, then copy it here again; never edit only this copy.
#
# Prepares the giraffe index set and the reference path list that the pangenome
# workflows take as inputs, starting from a single GBZ graph.
#
# Usage:
#   prepare_pangenome_indexes.sh <graph.gbz> <prefix> [ref_sample] [linear.fa]
#
#   <graph.gbz>   pangenome graph to index (PanSN-named reference paths expected)
#   <prefix>      output prefix; generated files are:
#                   <prefix>.ref_paths.txt
#                   <prefix>.dist / <prefix>.min / <prefix>.zipcodes
#                   <prefix>.snarls  (only needed for call_sv, see SKIP_SNARLS)
#   [ref_sample]  PanSN sample name of the reference paths (default: GRCh38, or
#                 auto-detected when the graph has no full-length GRCh38 paths,
#                 e.g. T2T-CHM13 backbone graphs such as JaSaPaGe)
#   [linear.fa]   linear FASTA used for CRAM/DeepVariant, validated against the
#                 reference extracted from the graph
#
# Environment:
#   SKIP_AUTOINDEX=1  skip `vg autoindex` and require <prefix>.dist/.min/.zipcodes
#                     to already exist (HPRC ships them)
#   SKIP_SNARLS=1     skip `vg snarls`; the snarls file is only consumed by the
#                     workflows' call_sv (SV genotyping) track, and computing it
#                     on a whole-genome graph is expensive
#   THREADS=N          threads for autoindex (default: all cores)
#   TMPDIR=DIR         directory for the intermediates vg autoindex spills
#                      (vg autoindex -T). On a cluster the default /tmp is
#                      usually a small node-local disk, far too small for a
#                      whole-genome graph, so point this at shared storage.
#   TARGET_MEM=SIZE    memory budget for vg autoindex (-M, e.g. 150G). vg
#                      defaults to half of what it sees on the machine, which
#                      ignores the cgroup limit of a batch job.
set -euo pipefail

GRAPH=${1:?usage: prepare_pangenome_indexes.sh <graph.gbz> <prefix> [ref_sample] [linear.fa]}
PREFIX=${2:?usage: prepare_pangenome_indexes.sh <graph.gbz> <prefix> [ref_sample] [linear.fa]}
REF_SAMPLE=${3:-}
LINEAR_FA=${4:-}
THREADS=${THREADS:-$(nproc)}

command -v vg >/dev/null 2>&1 || { echo "error: vg not found on PATH" >&2; exit 1; }

# Loading the path list from a large GBZ is expensive, so it is loaded exactly
# once and cached for the rest of the script.
ALL_PATHS_TMP=$(mktemp)
trap 'rm -f "$ALL_PATHS_TMP"' EXIT
vg paths -x "$GRAPH" -L > "$ALL_PATHS_TMP"

# A reference is a set of full-length PanSN paths like SAMPLE#HAP#chr1.
# Some graphs (e.g. JaSaPaGe) also carry hundreds of fragment/region paths whose
# names end in "[<pos>]" (GRCh38#0#chr1[585988]); those must not go into the
# ref_paths list that drives @SQ and surjection.
plain_ref_paths() {
  grep -E "^${1}#" "$ALL_PATHS_TMP" | grep -vE '\[[0-9]+\]$' || true
}

pick_ref_sample() {
  local best=""
  local best_n=0
  local s n
  for s in GRCh38 CHM13v2 CHM13; do
    n=$(plain_ref_paths "$s" | wc -l)
    if [ "$n" -gt "$best_n" ]; then best="$s"; best_n="$n"; fi
  done
  if [ -z "$best" ]; then
    echo "error: no full-length reference paths found in graph" >&2; exit 1
  fi
  echo "$best"
}

if [ -z "$REF_SAMPLE" ]; then
  REF_SAMPLE=$(pick_ref_sample)
  echo "auto-detected reference sample: ${REF_SAMPLE}"
fi

echo "[1/3] listing ${REF_SAMPLE} reference paths"
plain_ref_paths "$REF_SAMPLE" > "${PREFIX}.ref_paths.txt"
NREF=$(wc -l < "${PREFIX}.ref_paths.txt")
if [ "$NREF" -lt 10 ]; then
  echo "error: only ${NREF} full-length paths for ${REF_SAMPLE}; check the graph" >&2
  exit 1
fi
echo "  wrote ${PREFIX}.ref_paths.txt (${NREF} contigs)"

PREFIX_HINT=$(head -1 "${PREFIX}.ref_paths.txt" | sed -E 's/^([^#]+#[^#]+#).*/\1/')
echo "  set workflow input ref_path_prefix=${PREFIX_HINT}"

if [ -n "$LINEAR_FA" ]; then
  echo "[2/3] validating graph reference against ${LINEAR_FA}"
  vg paths -x "$GRAPH" -S "$REF_SAMPLE" -F > "${PREFIX}.reference.fa"
  python3 - "$PREFIX_HINT" "${PREFIX}.reference.fa" "$LINEAR_FA" <<'PYEOF'
import hashlib
import sys

prefix, gfa, lfa = sys.argv[1], sys.argv[2], sys.argv[3]


def read_fasta(path, strip_prefix):
    seqs = {}
    name = None
    buf = []
    for line in open(path):
        line = line.rstrip("\n")
        if line.startswith(">"):
            if name is not None:
                seqs[name] = "".join(buf)
            name = line[1:].split()[0]
            if strip_prefix and name.startswith(prefix):
                name = name[len(prefix):]
            buf = []
        else:
            buf.append(line)
    if name is not None:
        seqs[name] = "".join(buf)
    return seqs


graph_seq = read_fasta(gfa, True)
linear_seq = read_fasta(lfa, False)

fail = 0
for contig, seq in sorted(graph_seq.items()):
    if contig not in linear_seq:
        print(f"  FAIL {contig}: not found in linear FASTA"); fail += 1
        continue
    g_md5 = hashlib.md5(seq.encode()).hexdigest()
    l_md5 = hashlib.md5(linear_seq[contig].encode()).hexdigest()
    if g_md5 != l_md5:
        print(f"  FAIL {contig}: sequence differs from linear FASTA"); fail += 1
    else:
        print(f"  OK   {contig}")

sys.exit(1 if fail else 0)
PYEOF
  echo "  graph reference matches ${LINEAR_FA}"
else
  echo "[2/3] skipping linear FASTA check (no linear.fa argument)"
fi

echo "[3/3] building giraffe indexes"
if [ "${SKIP_AUTOINDEX:-0}" = "1" ]; then
  echo "  SKIP_AUTOINDEX=1: expecting ${PREFIX}.dist, ${PREFIX}.min, ${PREFIX}.zipcodes"
else
  AUTOINDEX_ARGS=( -p "$PREFIX" -G "$GRAPH" -w giraffe -t "$THREADS" )
  [ -n "${TMPDIR:-}" ] && AUTOINDEX_ARGS+=( -T "$TMPDIR" )
  [ -n "${TARGET_MEM:-}" ] && AUTOINDEX_ARGS+=( -M "$TARGET_MEM" )
  vg autoindex "${AUTOINDEX_ARGS[@]}"
  if [ ! -f "${PREFIX}.min" ] && [ -f "${PREFIX}.shortread.withzip.min" ]; then
    ln -s "${PREFIX}.shortread.withzip.min" "${PREFIX}.min"
  fi
  if [ ! -f "${PREFIX}.zipcodes" ] && [ -f "${PREFIX}.shortread.zipcodes" ]; then
    ln -s "${PREFIX}.shortread.zipcodes" "${PREFIX}.zipcodes"
  fi
fi

for f in "dist" "min" "zipcodes"; do
  [ -f "${PREFIX}.$f" ] || { echo "error: ${PREFIX}.$f missing" >&2; exit 1; }
done

# Snarls are consumed only by the SV genotyping track (call_sv). Computing them
# once here keeps vg call from recomputing them on every workflow run.
SNARLS_OUT=
if [ "${SKIP_SNARLS:-0}" = "1" ]; then
  echo "  SKIP_SNARLS=1: not building ${PREFIX}.snarls (needed only for call_sv)"
else
  echo "[extra] building snarls for SV genotyping (SKIP_SNARLS=1 to skip)"
  vg snarls -t "$THREADS" "$GRAPH" > "${PREFIX}.snarls"
  [ -s "${PREFIX}.snarls" ] || { echo "error: ${PREFIX}.snarls is empty" >&2; exit 1; }
  SNARLS_OUT=" ${PREFIX}.snarls"
fi

echo "done: ${PREFIX}.ref_paths.txt ${PREFIX}.dist ${PREFIX}.min ${PREFIX}.zipcodes${SNARLS_OUT}"