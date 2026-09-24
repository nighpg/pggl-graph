# Shared by build-release.sh (one node) and build-staged.sh (one stage of the
# multi-node build). Source it after setting SEQFILE, NAME and OUT; it sets
# up the images, CPUs, memory, work directories and logging, and defines the
# steps both builds share.
#
# Environment it reads (offline.env from setup-offline.sh provides the first
# two): CACTUS_SIF, VG_SIF, THREADS, MEM, WORKROOT, REF_CONTIGS, APPTAINER,
# PGGL_GRAPH_REV. See build-release.sh for what each means.

COMMON_HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
REPO=$(cd "$COMMON_HERE/.." && pwd)
SCRIPT=${SCRIPT:-$(basename "$0")}

: "${CACTUS_SIF:?set CACTUS_SIF (source offline.env)}"
: "${VG_SIF:?set VG_SIF (source offline.env)}"
CACTUS_SIF=$(readlink -f "$CACTUS_SIF")
VG_SIF=$(readlink -f "$VG_SIF")
AP=${APPTAINER:-$(command -v apptainer || command -v singularity || ls -d /opt/pkg/apptainer/*/bin/apptainer 2>/dev/null | sort -V | tail -1)}
[ -x "$AP" ] || { echo "$SCRIPT: apptainer not found; set APPTAINER" >&2; exit 1; }

THREADS=${THREADS:-${SLURM_CPUS_PER_TASK:-$(nproc)}}
# Toil caps itself at the CPUs this process may run on (the Slurm allocation),
# and a job asking for more than that kills the workflow outright
# (InsufficientSystemResources: cactus_cons requesting 16 cores, more than the
# maximum of 1). So THREADS may never exceed what is really there.
avail=$(nproc)
if [ "$THREADS" -gt "$avail" ]; then
    echo "$SCRIPT: THREADS=$THREADS but only $avail CPU(s) available here; using $avail" >&2
    echo "  (under Slurm, ask for the CPUs: srun/sbatch -c <n>)" >&2
    THREADS=$avail
fi

# Memory this job may use, in MB: Slurm's figure when it gives one, else the
# job's cgroup limit, else the machine's RAM -- scaled down to this job's share
# of the CPUs, so that several jobs sharing a node where Slurm does not manage
# memory (the build site) do not each believe they have all of it. Slurm leaves
# SLURM_MEM_PER_NODE unset there even with --mem=0.
available_mem_mb() {
    local total lim="" dir f v all
    total=$(awk '/^MemTotal:/ {print int($2 / 1024)}' /proc/meminfo)
    if [ -n "${SLURM_MEM_PER_NODE:-}" ] && [ "$SLURM_MEM_PER_NODE" -gt 0 ] 2>/dev/null; then
        lim=$SLURM_MEM_PER_NODE
    else
        # The limit sits on an ancestor (Slurm puts it on job_<id>, the
        # process lives in .../step_0/user/task_0), so walk up to the root and
        # keep the smallest. cgroup v2: "0::/path"; v1: "<n>:memory:/path".
        while IFS=: read -r _ ctrl path; do
            if [ -z "$ctrl" ]; then dir=/sys/fs/cgroup$path; f=memory.max
            elif [[ ",$ctrl," == *,memory,* ]]; then dir=/sys/fs/cgroup/memory$path; f=memory.limit_in_bytes
            else continue; fi
            while :; do
                if [ -r "$dir/$f" ]; then
                    v=$(awk '$1 ~ /^[0-9]+$/ {print int($1 / 1048576)}' "$dir/$f")
                    if [ -n "$v" ] && { [ -z "$lim" ] || [ "$v" -lt "$lim" ]; }; then lim=$v; fi
                fi
                case $dir in /sys/fs/cgroup|/sys/fs/cgroup/memory|/) break ;; esac
                dir=${dir%/*}
            done
        done < /proc/self/cgroup
    fi
    if [ -z "$lim" ] || [ "$lim" -ge "$total" ]; then
        all=$(nproc --all)
        lim=$(( total * $(nproc) / all ))
    fi
    echo "$lim"
}
if [ -z "${MEM:-}" ]; then
    MEM="$(( $(available_mem_mb) * 95 / 100 / 1024 ))G"
fi

mkdir -p "$OUT"/{cactus,release,logs}
OUT=$(cd "$OUT" && pwd)
if [ -z "${WORKROOT:-}" ]; then
    if [ -d /scratch ]; then WORKROOT=/scratch/$USER/pggl-graph-$NAME; else WORKROOT=$OUT/work; fi
fi
mkdir -p "$WORKROOT/toil"

log() { echo "[$(date -Is)] $*"; }
binds() { printf '%s\n' "$@" | tr ',' '\n' | sed '/^$/d' | sort -u | paste -sd, -; }

# git may be missing on compute nodes; offline.env then carries the bundle's commit
repo_rev() {
    local rev
    if rev=$(git -C "$REPO" rev-parse --short HEAD 2>/dev/null); then
        git -C "$REPO" diff --quiet HEAD 2>/dev/null || rev="$rev-dirty"
    else
        rev=${PGGL_GRAPH_REV:-unknown}
    fi
    echo "$rev"
}

# check-seqfile.py, then REF_FASTA, INPUT_DIRS, N_SAMPLES, N_HAPS for what follows
preflight() {
    python3 "$COMMON_HERE/check-seqfile.py" "$SEQFILE" ${REF_CONTIGS:+--ref-contigs "$REF_CONTIGS"} \
        --summary "$OUT/logs/seqfile-summary.json" --absolute "$OUT/cactus.seqfile.txt" || exit 1
    eval "$(python3 - "$OUT/logs/seqfile-summary.json" <<'EOF'
import json, shlex, sys
s = json.load(open(sys.argv[1]))
print("REF_FASTA=%s" % shlex.quote(s["reference_fasta"]))
print("INPUT_DIRS=%s" % shlex.quote(",".join(s["dirs"])))
print("N_SAMPLES=%d N_HAPS=%d" % (s["samples"], s["haplotypes"]))
EOF
)"
    cp "$SEQFILE" "$OUT/release/$NAME.seqfile.txt"
}

# build-info.json for the manifest; $1 = how Cactus was run
write_build_info() {
    local mode=$1 versions cactus_v toil_v cactus_vg
    versions=$("$AP" exec --cleanenv "$CACTUS_SIF" bash -c \
        'pip list 2>/dev/null | awk "/^(Cactus|toil) /{print \$2}"; vg version | awk "NR == 1 {print \$3}"')
    read -r cactus_v toil_v cactus_vg <<< "$(echo $versions)"
    python3 - "$OUT/logs/build-info.json" "$cactus_v" "$toil_v" "$cactus_vg" "$CACTUS_SIF" \
        "$N_SAMPLES" "$N_HAPS" "${CACTUS_EXTRA:-}" "${BUILD_NOTE:-}" "$mode" <<'EOF'
import datetime, hashlib, json, os, sys
out, cv, tv, vg, sif, ns, nh, extra, note, mode = sys.argv[1:]
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
                "gfa": ["clip", "filter"], "run": mode},
}
if extra:
    info["options"]["extra"] = extra
if note:
    info["note"] = note
json.dump(info, open(out, "w"), indent=2)
EOF
}

# [D]-[E]: vg indexes, reference, manifest, validation. Returns
# validate-graph.sh's status (0 pass, 3 a check failed) or the failing step's.
run_index_release() {
    local rc=0
    "$AP" exec --cleanenv --bind "$(binds "$REPO" "$OUT" "$WORKROOT" "$(dirname "$REF_FASTA")")" \
        --env TMPDIR="$WORKROOT",SITE="${SITE:-build}",SITE_ROOT="${SITE_ROOT:-}",RELEASE_LABEL="${RELEASE_LABEL:-}",TARGET_MEM="$MEM",PGGL_GRAPH_REV="$(repo_rev)",INDEX_IMAGE_REF="$(basename "$VG_SIF")",INDEX_IMAGE_SHA256="$(sha256sum "$VG_SIF" | cut -d' ' -f1)" \
        "$VG_SIF" \
        bash "$REPO/scripts/index-release.sh" "$NAME" "$OUT/release" \
            "$OUT/cactus/$NAME.gfa.gz" "$OUT/cactus/$NAME.d2.gfa.gz" "$REF_FASTA" \
            "$OUT/logs/build-info.json" "$THREADS" || rc=$?
    return $rc
}
