#!/usr/bin/env bash
#
# Builds a release on one node: Minigraph-Cactus (cactus-pangenome --mgSplit,
# in the Cactus image), then stages [D]-[E] (scripts/index-release.sh, in the
# per-sample vg image). No network is needed. tests/toy/build.sh runs this same
# script, so the toy exercises exactly the production code path.
#
# Usage: build-release.sh <seqfile> <name> <outdir>
#
#   <outdir>/cactus/     Cactus outputs (<name>.gfa.gz = clip, <name>.d2.gfa.gz
#                        = filter, <name>.full.hal, stats, <name>.WARNING)
#   <outdir>/release/    the release: <name>.{clip,filter}.*, <name>.ref.*,
#                        graph.manifest.json, validation/
#   <outdir>/logs/       cactus.log
#
# Environment (offline.env from setup-offline.sh provides the first two):
#   CACTUS_SIF, VG_SIF   the images (required)
#   THREADS              cores for Cactus and vg (default: the Slurm allocation, else nproc)
#   MEM                  memory ceiling for Toil and vg autoindex, e.g. 950G
#                        (default: 95% of the Slurm allocation; required outside Slurm)
#   WORKROOT             fast local scratch for Toil's work dir and vg's
#                        temporaries (default: /scratch/$USER/pggl-graph-<name>
#                        when /scratch exists, else <outdir>/work)
#   JOBSTORE             Toil job store (default: $WORKROOT/jobstore). Put it on
#                        the shared filesystem to be able to restart on another node.
#   REF_CONTIGS          expected reference contigs (default: the 25 GRCh38
#                        primary contigs; see check-seqfile.py)
#   RELEASE_LABEL        manifest release label (default: today's date)
#   SITE, SITE_ROOT      manifest site name (default "build") and release root
#                        (default: the absolute release directory)
#   CACTUS_EXTRA         extra cactus-pangenome options, word-split
#   BUILD_NOTE           free text for the manifest's build.note
#
# Restarting: run the same command again. Cactus is skipped when both GFAs are
# already there, restarted from its job store (--restart) when that exists,
# and started afresh otherwise. The vg stages always rerun; they take hours at
# full scale against days for Cactus.
#
# Exit: validate-graph.sh's (0 pass, 3 a check failed), or the failing step's.
set -euo pipefail

SEQFILE=${1:?usage: build-release.sh <seqfile> <name> <outdir>}
NAME=${2:?usage: build-release.sh <seqfile> <name> <outdir>}
OUT=${3:?usage: build-release.sh <seqfile> <name> <outdir>}
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO=$(cd "$HERE/.." && pwd)

: "${CACTUS_SIF:?set CACTUS_SIF (source offline.env)}"
: "${VG_SIF:?set VG_SIF (source offline.env)}"
CACTUS_SIF=$(readlink -f "$CACTUS_SIF")
VG_SIF=$(readlink -f "$VG_SIF")
AP=${APPTAINER:-$(command -v apptainer || command -v singularity || ls -d /opt/pkg/apptainer/*/bin/apptainer 2>/dev/null | sort -V | tail -1)}
[ -x "$AP" ] || { echo "build-release.sh: apptainer not found; set APPTAINER" >&2; exit 1; }

THREADS=${THREADS:-${SLURM_CPUS_PER_TASK:-$(nproc)}}
# Toil caps itself at the CPUs this process may run on (the Slurm allocation),
# and a job asking for more than that kills the workflow outright
# (InsufficientSystemResources: cactus_cons requesting 16 cores, more than the
# maximum of 1). So THREADS may never exceed what is really there.
avail=$(nproc)
if [ "$THREADS" -gt "$avail" ]; then
    echo "build-release.sh: THREADS=$THREADS but only $avail CPU(s) available here; using $avail" >&2
    echo "  (under Slurm, ask for the CPUs: srun/sbatch -c <n>)" >&2
    THREADS=$avail
fi
if [ -z "${MEM:-}" ]; then
    [ -n "${SLURM_MEM_PER_NODE:-}" ] \
        || { echo "build-release.sh: set MEM (e.g. 950G) outside a Slurm job" >&2; exit 1; }
    MEM="$((SLURM_MEM_PER_NODE * 95 / 100 / 1024))G"
fi
mkdir -p "$OUT"/{cactus,release,logs}
OUT=$(cd "$OUT" && pwd)
if [ -z "${WORKROOT:-}" ]; then
    if [ -d /scratch ]; then WORKROOT=/scratch/$USER/pggl-graph-$NAME; else WORKROOT=$OUT/work; fi
fi
JOBSTORE=${JOBSTORE:-$WORKROOT/jobstore}
mkdir -p "$WORKROOT/toil" "$(dirname "$JOBSTORE")"
log() { echo "[$(date -Is)] $*"; }
binds() { printf '%s\n' "$@" | tr ',' '\n' | sort -u | paste -sd, -; }

log "build-release.sh $NAME: $THREADS threads, $MEM, work in $WORKROOT, job store $JOBSTORE"
log "images: $(basename "$CACTUS_SIF"), $(basename "$VG_SIF")"

# --- preflight --------------------------------------------------------------
python3 "$HERE/check-seqfile.py" "$SEQFILE" ${REF_CONTIGS:+--ref-contigs "$REF_CONTIGS"} \
    --summary "$OUT/logs/seqfile-summary.json" --absolute "$OUT/cactus.seqfile.txt"
eval "$(python3 - "$OUT/logs/seqfile-summary.json" <<'EOF'
import json, shlex, sys
s = json.load(open(sys.argv[1]))
print("REF_FASTA=%s" % shlex.quote(s["reference_fasta"]))
print("INPUT_DIRS=%s" % shlex.quote(",".join(s["dirs"])))
print("N_SAMPLES=%d N_HAPS=%d" % (s["samples"], s["haplotypes"]))
EOF
)"
cp "$SEQFILE" "$OUT/release/$NAME.seqfile.txt"

# --- [A]-[C]: Minigraph-Cactus ------------------------------------------------
CACTUS_OPTS=(--reference GRCh38 --mgSplit --gfa clip filter)
if [ -s "$OUT/cactus/$NAME.gfa.gz" ] && [ -s "$OUT/cactus/$NAME.d2.gfa.gz" ]; then
    log "Cactus outputs present; skipping cactus-pangenome"
else
    restart=()
    if [ -d "$JOBSTORE" ]; then
        log "job store exists: restarting cactus-pangenome"
        restart=(--restart)
    else
        log "cactus-pangenome"
    fi
    # shellcheck disable=SC2086
    "$AP" exec --cleanenv --bind "$(binds "$OUT" "$WORKROOT" "$(dirname "$JOBSTORE")" "$INPUT_DIRS")" "$CACTUS_SIF" \
        cactus-pangenome "$JOBSTORE" "$OUT/cactus.seqfile.txt" \
        --outDir "$OUT/cactus" --outName "$NAME" "${CACTUS_OPTS[@]}" \
        --binariesMode local --maxCores "$THREADS" --maxMemory "$MEM" \
        --workDir "$WORKROOT/toil" --logFile "$OUT/logs/cactus.log" \
        "${restart[@]}" ${CACTUS_EXTRA:-}
    [ -f "$OUT/cactus/$NAME.WARNING" ] && { log "Cactus left a warning:"; cat "$OUT/cactus/$NAME.WARNING"; }
fi

versions=$("$AP" exec --cleanenv "$CACTUS_SIF" bash -c \
    'pip list 2>/dev/null | awk "/^(Cactus|toil) /{print \$2}"; vg version | head -1 | awk "{print \$3}"')
read -r cactus_v toil_v cactus_vg <<< "$(echo $versions)"
python3 - "$OUT/logs/build-info.json" "$cactus_v" "$toil_v" "$cactus_vg" "$CACTUS_SIF" \
    "$N_SAMPLES" "$N_HAPS" "${CACTUS_EXTRA:-}" "${BUILD_NOTE:-}" <<'EOF'
import datetime, hashlib, json, os, sys
out, cv, tv, vg, sif, ns, nh, extra, note = sys.argv[1:]
h = hashlib.sha256()
with open(sif, "rb") as f:
    for chunk in iter(lambda: f.read(1 << 24), b""):
        h.update(chunk)
info = {
    "method": "minigraph-cactus",
    "date": datetime.date.today().isoformat(),
    "cactus_version": cv,
    "toil_version": tv,
    "cactus_image": {"ref": "docker://quay.io/comparative-genomics-toolkit/cactus:v" + cv,
                     "file": os.path.basename(sif), "sha256": h.hexdigest()},
    "cactus_internal_vg": vg,
    "reference_order": ["GRCh38"],
    "reference_order_source": "recorded",
    "samples": int(ns),
    "haplotypes": int(nh),
    "options": {"reference": ["GRCh38"], "mgSplit": True, "clip": 10000, "filter": 2,
                "gfa": ["clip", "filter"]},
}
if extra:
    info["options"]["extra"] = extra
if note:
    info["note"] = note
json.dump(info, open(out, "w"), indent=2)
EOF

# --- [D]-[E]: vg indexes, reference, manifest, validation ------------------
log "index-release.sh"
rev=$(git -C "$REPO" rev-parse --short HEAD 2>/dev/null || echo unknown)
git -C "$REPO" diff --quiet HEAD 2>/dev/null || rev="$rev-dirty"
rc=0
"$AP" exec --cleanenv --bind "$(binds "$REPO" "$OUT" "$WORKROOT" "$(dirname "$REF_FASTA")")" \
    --env TMPDIR="$WORKROOT",SITE="${SITE:-build}",SITE_ROOT="${SITE_ROOT:-}",RELEASE_LABEL="${RELEASE_LABEL:-}",TARGET_MEM="$MEM",PGGL_GRAPH_REV="$rev",INDEX_IMAGE_REF="$(basename "$VG_SIF")",INDEX_IMAGE_SHA256="$(sha256sum "$VG_SIF" | cut -d' ' -f1)" \
    "$VG_SIF" \
    bash "$REPO/scripts/index-release.sh" "$NAME" "$OUT/release" \
        "$OUT/cactus/$NAME.gfa.gz" "$OUT/cactus/$NAME.d2.gfa.gz" "$REF_FASTA" \
        "$OUT/logs/build-info.json" "$THREADS" || rc=$?
log "done: $OUT/release (exit $rc)"
exit $rc
