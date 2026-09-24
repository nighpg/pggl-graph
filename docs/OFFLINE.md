# Building a graph on the air-gapped site

This is the whole procedure, from collecting the software on an online host to
a validated release that pggl-workflow can use:

```
online host                    build site (air-gapped)                     where pggl-workflow runs
───────────                    ───────────────────────                     ────────────────────────
1. fetch-offline-bundle.sh ─┐
                            ├─▶ 3. setup-offline.sh --verify
2. assemblies + seqfile  ───┘   4. check-seqfile.py
                                5. submit-staged.sh             (days)
                                6. check the release           ───────▶  7. add a site, check, use
```

The build never needs the network. Cactus runs its binaries from its own image
(`--binariesMode local`), and every vg step runs in the per-sample vg image.
The toy build and the install with `--verify` both pass inside `unshare -rn`
(a network namespace with only loopback). Only step 1 downloads anything.

The build site as of 2026-09:

| | |
| --- | --- |
| Slurm partition | `compute001-006` (6 nodes) |
| Node | 128 CPU, 1031 GB |
| Shared filesystem | `/home` (inputs, outputs, the checkout) |
| Node-local SSD | `/scratch`, 1.5 TB (Toil's work directory and job store) |
| Not visible | `/lustre*` |

The layout used below, all under the shared `/home`:

```
/home/<user>/pangenome/
├── pggl-graph/        the checkout, both SIFs, offline.env   (step 3)
├── reference/         GRCh38.primary.fa                      (step 3)
├── assemblies/        the input FASTAs                       (step 2)
├── seqfiles/          one seqfile per build                  (step 4)
├── builds/<name>/     cactus/, release/, logs/               (step 5)
└── logs/              Slurm logs
```

## 1. Collect the software (online host)

```bash
cd pggl-graph
scripts/fetch-offline-bundle.sh \
    --vg-sif ../pggl-workflow/deepvariant-opencode-cpu-vg.sif \
    --grch38 /lustre9/open/shared_data/public-human-genomes/GRCh38/fasta/GRCh38_full_analysis_set_plus_decoy_hla.fa \
    --archive
```

This takes about a minute and produces `pggl-graph-offline-bundle-<date>.tar`
(5.3 GB) with its `.sha256`:

```
offline-bundle/
├── sif/          cactus_v3.3.0.sif (0.5 GB)
│                 deepvariant-opencode-cpu-vg.sif (2.0 GB, vg v1.70.0)
├── reference/    GRCh38.primary.fa (3.1 GB), GRCh38.primary.m5.tsv, SOURCE.tsv
├── repo/         pggl-graph.bundle (git, full history), pggl-graph-<rev>.tar.gz
├── setup-offline.sh, README-offline.md (this file)
└── BUNDLE_INFO.txt, SHA256SUMS
```

- **Commit first.** The bundle holds the last commit; the script warns about
  uncommitted changes and leaves them out.
- **The vg image must be the one pggl-workflow runs.** Every index is built
  with it, and a different vg writes files the per-sample side can refuse
  (`.hapl` v4, GBZ v2).
- **GRCh38.primary.fa** is the 25 primary contigs (chr1-22, X, Y, M) of the
  analysis set, sequences untouched (`scripts/grch38-primary.py`). It becomes
  the reference of the graph. Decoys, alts, HLA and EBV are left out, so
  GRCh38 stays at 25 paths. The sequences are untouched, so the reference
  extracted from the graph is M5-identical to the analysis set on those 25
  contigs. The full analysis set is not needed on the build site. It is
  needed where pggl-workflow decodes CRAMs (step 7). Without `--grch38` the
  script downloads the analysis set from 1000 Genomes.
- `--split 20G` splits the `.tar` for media with a file size limit. Downloads
  and `apptainer pull` retry on transient errors (`scripts/lib/retry.sh`).

## 2. Carry the bundle and the assemblies

Copy the `.tar` and the assemblies to `/home/<user>/pangenome/` on the build
site. After `--split`, reassemble and check:

```bash
cat pggl-graph-offline-bundle-<date>.tar.part-* > pggl-graph-offline-bundle-<date>.tar
sha256sum -c pggl-graph-offline-bundle-<date>.tar.sha256
tar xf pggl-graph-offline-bundle-<date>.tar
```

The assemblies are not in the bundle, because they are chosen per build. Carry
one FASTA (plain or gzipped) per haplotype, with a checksum list made before
the transfer.

## 3. Install and verify (build site)

```bash
cd /home/<user>/pangenome
srun -p compute001-006 -c 16 --mem 32G \
    bash offline-bundle/setup-offline.sh --bundle offline-bundle --dest . --verify
```

This checks `SHA256SUMS` and clones the repository to `pggl-graph/`, or unpacks
the tarball when git is missing. It then copies the SIFs next to the checkout
and the reference to `reference/`, and writes `pggl-graph/offline.env`:

```bash
CACTUS_SIF=/home/<user>/pangenome/pggl-graph/cactus_v3.3.0.sif
VG_SIF=/home/<user>/pangenome/pggl-graph/deepvariant-opencode-cpu-vg.sif
GRCH38_PRIMARY=/home/<user>/pangenome/reference/GRCh38.primary.fa
```

Give the job CPUs with `-c`: the toy uses as many as the job has (`nproc`).
Before this was fixed, a job without `-c` failed in Cactus with
`InsufficientSystemResources: ... requesting 16.0 cores, more than the maximum
of 1`.

`--verify` builds the toy release from the checked-in assemblies with the same
script as step 5, in `/scratch/$USER/pggl-graph-toy`, which takes about 3
minutes. It passes only when validation passes **and** every reproducible file
is byte-identical to `tests/toy/expected/`. The distance and minimizer indexes
are exempt, because vg does not build them deterministically. A pass shows
that the images, apptainer, Slurm and the scripts all work on this site.
**Do not start step 5 until it passes.**

The toy can also be built the multi-node way, stage by stage on the same node,
to check that path too (about 7 minutes):

```bash
srun -p compute001-006 -c 16 --mem 32G env TOY_BUILD=staged TOY_MODE=check \
    bash pggl-graph/tests/toy/build.sh pggl-graph/cactus_v3.3.0.sif \
    pggl-graph/deepvariant-opencode-cpu-vg.sif /scratch/$USER/toy-staged
```

## 4. Write and check the seqfile

One line per haplotype: a name and the FASTA's path, separated by a tab.

```
GRCh38	/home/<user>/pangenome/reference/GRCh38.primary.fa
CHM13	/home/<user>/pangenome/assemblies/chm13v2.0.fa.gz
NA18940.1	/home/<user>/pangenome/assemblies/NA18940.hap1.fa.gz
NA18940.2	/home/<user>/pangenome/assemblies/NA18940.hap2.fa.gz
...
```

The rules:

- **`GRCh38` first, and only there.** Minigraph-Cactus leaves only the first
  reference unclipped. JaSaPaGe listed CHM13v2 first, and its GRCh38 was cut
  into 166 subrange paths (see README.md).
- **GRCh38 is `GRCh38.primary.fa`**: exactly 25 contigs.
- **Diploid samples are `SAMPLE.1` and `SAMPLE.2`**. They become the PanSN
  paths `SAMPLE#1#<contig>` and `SAMPLE#2#<contig>`. A haploid assembly is
  just `SAMPLE`. No `#` in names.
- **CHM13 is an ordinary haplotype** (`CHM13`, no suffix), not a reference.
- Absolute paths, on `/home`. Plain local paths only: the site has no network.

Check it before submitting. This reads the headers of GRCh38 and every file
path, and takes seconds:

```bash
cd /home/<user>/pangenome/pggl-graph
python3 scripts/check-seqfile.py ../seqfiles/<name>.txt
```

It lists every problem and exits 1 if there is any. `build-release.sh` runs the
same check first and stops on failure, but checking now saves a queue wait.
Run against JaSaPaGe's seqfile, it reports "the first entry is CHM13v2, not
GRCh38 (it is on line 2)".

## 5. Build

There are two ways to build, and both produce the same release. On the toy,
the multi-node build reproduces the one-node build's GBZs, reference and
indexes byte for byte.

| | Multi-node (`scripts/submit-staged.sh`) | One node (`sbatch/build-release.sbatch`) |
| --- | --- | --- |
| Use for | the whole genome | pilots (one or two chromosomes), small builds |
| Nodes | up to 6: one chromosome per node at a time | 1 |
| Chromosomes | built in parallel, largest first | one after another (each takes all 128 cores) |
| Resuming | per step and per chromosome, on any node | from the Toil job store, on the same node |

Why it matters: on the chr21 pilot (40 haplotypes), building the chromosome's
minigraph alone took 4 hours with all 128 cores. On one node the 25
chromosomes take their turn at that, one after another.

### Multi-node

Run on the login node. It checks the seqfile, submits four jobs chained by
dependencies, and returns:

```bash
cd /home/<user>/pangenome/pggl-graph         # every job reads offline.env from here
scripts/submit-staged.sh -p compute001-006 \
    --time-bin 12:00:00 --time-chrom 3-00:00:00 --time-join 1-00:00:00 --time-index 1-00:00:00 \
    --seqfile ../seqfiles/<name>.txt --name <name> --out ../builds/<name>
```

```
bin  ──▶  chrom (array of 25, one task per chromosome)  ──▶  join  ──▶  index
```

| Stage | Job | What |
| --- | --- | --- |
| `bin` | 1 whole node | input contig sizes (for the exclusion report), a reference-only minigraph, every assembly mapped to it, contigs binned by chromosome. It lists the chromosomes largest first |
| `chrom` | array, 1 whole node per task | per chromosome: `cactus-minigraph`, `cactus-graphmap`, `cactus-align --pangenome`, each given the task's whole node. Task 0 is the largest chromosome |
| `join` | 1 whole node | `cactus-graphmap-join`: the clip and filter GFAs, the HAL, the exclusion report (`<name>.WARNING`) |
| `index` | 1 whole node | as in the one-node build: GBZs with vg 1.70, indexes, reference, manifest, validation |

Options worth knowing (`scripts/submit-staged.sh --help` has them all):

- `--chrom-cpus 64` runs two chromosomes per node (12 at once on 6 nodes). It
  has more parallelism, but half the memory per chromosome. Start with whole
  nodes until the memory of the largest chromosome is known.
- `--max-running N` caps how many chromosome tasks run at once, to leave nodes
  for others.
- `--tasks N` is the array size (default 25). Tasks without a chromosome exit
  at once, so a pilot with `CACTUS_EXTRA='--refContigs chr21'` needs no change.
- `--from chrom|join|index` resumes the chain at a stage. A failed stage
  leaves the later jobs pending with `DependencyNeverSatisfied`: `scancel`
  them, fix the cause, and resubmit with `--from <failed stage>`. Steps that
  finished are skipped, including the chromosomes that finished, so rerunning
  the whole array costs only the chromosomes that failed.
- `--dry-run` prints the `sbatch` commands without submitting.

Other build settings (`CACTUS_EXTRA`, `RELEASE_LABEL`, `BUILD_NOTE`,
`WORKROOT`) are read from the submitting shell's environment, so export them
first. Values with commas or spaces need no quoting.

Where things go:

```
builds/<name>/
├── cactus/
│   ├── <name>.input-contig-sizes.tsv.gz, <name>.sv.gfa.gz, <name>.paf   (bin)
│   ├── chrom-subproblems/, chroms.txt                                     (bin)
│   ├── chroms/<chrom>/{minigraph,graphmap,align}/                         (chrom)
│   └── <name>.gfa.gz, <name>.d2.gfa.gz, <name>.full.hal, <name>.WARNING   (join)
├── release/                        (index; as in step 6)
└── logs/
    ├── slurm/<stage>-<jobid>[_<task>].out, jobs.txt
    └── <stage>/<step>.log          one Cactus log per step
```

Watching it:

```bash
squeue -u $USER -n pggl-<name>-bin,pggl-<name>-chrom,pggl-<name>-join,pggl-<name>-index
tail -f ../builds/<name>/logs/slurm/chrom-<jobid>_0.out     # the largest chromosome
ls ../builds/<name>/cactus/chroms/*/align/*.hal              # chromosomes finished so far
```

### One node

```bash
cd /home/<user>/pangenome/pggl-graph
mkdir -p ../logs
sbatch -p compute001-006 -c 128 -t <walltime> -o ../logs/build-<name>-%j.out \
    --export=ALL,SEQFILE=../seqfiles/<name>.txt,NAME=<name>,OUT=../builds/<name> \
    sbatch/build-release.sbatch
```

The job takes a whole node (`--exclusive --mem=0`) and runs
`scripts/build-release.sh`:

| Step | Where | What |
| --- | --- | --- |
| preflight | host | `check-seqfile.py`; an absolute-path copy of the seqfile for Cactus |
| [A]-[C] | Cactus image | `cactus-pangenome --reference GRCh38 --mgSplit --gfa clip filter --binariesMode local`, Toil on this node only, capped at the allocation (`--maxCores`, `--maxMemory` = 95% of the node) |
| [D]-[E] | vg image | `scripts/index-release.sh`: GBZ v1 from each GFA, reference extracted and M5-checked against `GRCh38.primary.fa`, giraffe indexes (filter), `ri`/`hapl` (clip), snarls (both), manifest, `validate-graph.sh` |

Where things go:

```
builds/<name>/
├── cactus/        <name>.gfa.gz (clip), <name>.d2.gfa.gz (filter), <name>.full.hal,
│                  <name>.stats/, chrom-*/ , <name>.WARNING (if any)
├── release/       the release (step 6)
├── logs/          cactus.log, build-info.json, seqfile-summary.json
└── cactus.seqfile.txt
/scratch/<user>/pggl-graph-<name>/   Toil work directory and job store (node-local)
```

**Resources.** None of this has been measured at full scale yet. For scale,
JaSaPaGe (134 haplotypes) left 171 GB of top-level outputs and another 203 GB
of per-chromosome alignments, so keep at least 500 GB free on `/home`. The
release itself is about 75 GB. How much of `/scratch`'s 1.5 TB the job store
needs is unknown; if it fills, set `JOBSTORE=/home/...` (slower, but it also
lets the build resume on another node). For the walltime, do not guess high:
an inflated `-t` keeps the job from backfilling. A pilot on one chromosome
gives a first figure. Add `CACTUS_EXTRA='--refContigs chr21'` to the
`--export`, and use a separate `NAME` and `OUT`. Its validation fails, because
it has one contig instead of 25, but its timings are what matter.

**Watching it.**

```bash
tail -f ../logs/build-<name>-<jobid>.out           # the step markers, [date] ...
grep -c 'Issued job' ../builds/<name>/logs/cactus.log   # Toil progress
ls ../builds/<name>/cactus/                        # outputs appear chromosome by chromosome
```

**Resuming.** Submit the same command again, after a failure or a timeout.
`build-release.sh` skips Cactus when both GFAs exist. When the job store
exists, it restarts Cactus from there (`--restart`). The vg stages always
rerun; they are hours against Cactus's days. Because the job store is on the
node's `/scratch`, the resubmission must land on the same node: add `-w
<node>`, which the first log names on its `host` line. With `JOBSTORE` on
`/home`, any node will do. To start over, delete `builds/<name>/` and the job
store.

## 6. Check the release

The job's exit status is `validate-graph.sh`'s: 0 when every check passes, 3
when one fails. The log ends with the check table, and the same results are
in the manifest:

```bash
cd /home/<user>/pangenome/builds/<name>/release
cat validation/validation.log
python3 ../../../pggl-graph/scripts/manifest.py check graph.manifest.json --site build --md5 --contract
```

`--contract` exits 0 only when GRCh38 is 25 whole paths, the reference came
from the graph and matches `GRCh38.primary.fa`, every index was made by the
vg in `index_builder`, and validation passed. Also read
`../cactus/<name>.WARNING` if it exists. It lists input sequence that reached
no chromosome graph, such as unplaced contigs, which is expected in small
amounts.

The release directory:

```
<name>.clip.gbz  .dist  .ri  .hapl  .snarls              haplotype sampling, call_sv
<name>.filter.gbz  .dist  .min  .zipcodes  .snarls       giraffe
<name>.ref.fa  .fa.fai  .dict  .pansn.dict               ref, ref_paths
<name>.seqfile.txt  graph.manifest.json  validation/
```

## 7. Bring it back

Copy `release/` to the shared filesystem where pggl-workflow runs. Keep
`cactus/` on the build site, or archive it; pggl-workflow does not use it.
Paths in the manifest are relative to a root named per site, so the new
location is one more entry under `sites`, next to `build`:

```json
"sites": {
  "build":      {"roots": {"release": "/home/<user>/pangenome/builds/<name>/release"}},
  "nig-lustre": {"roots": {"release": "/lustre10/.../<name>"}}
}
```

Check it where it now lives, commit the manifest to this repository as
`releases/<name>/graph.manifest.json`, and print pggl-workflow's inputs:

```bash
python3 scripts/manifest.py check releases/<name>/graph.manifest.json --site nig-lustre --md5 --contract
python3 scripts/manifest.py job releases/<name>/graph.manifest.json --site nig-lustre > <name>.inputs.json
```

The `ref` in that output is the release's own 25-contig reference. It is
right for FASTQ and BAM input, but **not for CRAM input**. pggl-workflow
decodes CRAMs with `ref`, and a CRAM against the analysis set has reads on
decoy and HLA contigs that the 25-contig reference lacks. The decode stops
there, unless htslib happens to find the original FASTA through the CRAM
header's `UR:` path. For CRAMs, pass the FASTA they were encoded against. Its
25 reference contigs are checked against the release before it is used:

```bash
python3 scripts/manifest.py job releases/<name>/graph.manifest.json --site nig-lustre \
    --cram-reference /lustre9/open/shared_data/public-human-genomes/GRCh38/fasta/GRCh38_full_analysis_set_plus_decoy_hla.fa \
    > <name>.cram-inputs.json
```

## When something fails

| Symptom | Cause and remedy |
| --- | --- |
| `setup-offline.sh: the bundle is damaged` | Transfer damage: copy the `.tar` again and compare its `.sha256` |
| `--verify` shows `DIFF` for a GBZ or `toy.ref.*` | A different image than the bundled one, or a modified checkout. Reinstall from the bundle |
| `check-seqfile.py`: "the first entry is ..." | Move the `GRCh38` line to the top |
| `check-seqfile.py`: "contigs beyond the expected 25" | GRCh38 is the full analysis set: use `GRCh38.primary.fa` |
| `InsufficientSystemResources: ... requesting N cores, more than the maximum of 1` | The job had fewer CPUs than `THREADS` asked for. Fixed: `THREADS` is now capped at the CPUs available, but give the job its CPUs with `srun -c` / `sbatch -c` |
| `build-release.sh: set MEM (e.g. 950G) outside a Slurm job` (log shows `mem: ? MB`) | The build site's Slurm does not set `SLURM_MEM_PER_NODE`. Fixed: the memory now comes from the job's cgroup limit or the node's RAM. With the old code, add `MEM=950G` to `--export` |
| `FAIL chr21: graph ... bp M5 ..., source ... bp M5 ...` with equal lengths, after Cactus finished | GRCh38's IUPAC codes (M, R, ...) are N in the graph. Fixed: the check now allows exactly that. With the fix, rerun the same command: Cactus is skipped and only the vg stages run |
| `apptainer not found` | Not on PATH on the compute node: set `APPTAINER=/opt/pkg/apptainer/<ver>/bin/apptainer` |
| A resumed build starts Cactus from the beginning | It landed on another node, whose `/scratch` has no job store. Resubmit with `-w <first node>`, or put `JOBSTORE` on `/home` from the start |
| `/scratch` full | Set `JOBSTORE` (and, if needed, `WORKROOT`) under `/home` and start over |
| Validation check 4 fails for the GBZ | The GBZ was not rebuilt by the vg image (for example Cactus's own GBZ was used). `index-release.sh` always rebuilds it from the GFA |
