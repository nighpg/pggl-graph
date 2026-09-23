# Building on the air-gapped site

The build itself never needs the network. Cactus runs its binaries from its own
image (`--binariesMode local`), and every vg step runs in the per-sample vg
image. The toy build passes every check inside `unshare -rn` (a network
namespace with nothing but loopback). Only collecting the images and the
reference needs internet access, and the two scripts split along that line:

| Script | Where it runs | What it does |
| --- | --- | --- |
| `scripts/fetch-offline-bundle.sh` | online host | collects the images, the GRCh38 input and this repository into `offline-bundle/` (optionally one `.tar`) |
| `scripts/setup-offline.sh` | build site | checks the bundle, installs it, and with `--verify` builds the toy release and compares it with the checked-in one |

The build site as of 2026-09: Slurm partition `compute001-006` (6 nodes, 128
CPU / 1031 GB each), shared filesystem `/home`, node-local SSD `/scratch`
(1.5 TB). `/lustre*` is not visible there.

## 1. On the online host

```bash
cd pggl-graph
scripts/fetch-offline-bundle.sh \
    --vg-sif ../pggl-workflow/deepvariant-opencode-cpu-vg.sif \
    --grch38 /lustre9/open/shared_data/public-human-genomes/GRCh38/fasta/GRCh38_full_analysis_set_plus_decoy_hla.fa \
    --archive
```

```
offline-bundle/
├── sif/          cactus_v3.3.0.sif (0.5 GB)
│                 deepvariant-opencode-cpu-vg.sif (2.0 GB, vg v1.70.0)
├── reference/    GRCh38.primary.fa (3.1 GB), its M5 sums, SOURCE.tsv
├── repo/         pggl-graph.bundle (git, full history), pggl-graph-<rev>.tar.gz
├── setup-offline.sh, README-offline.md (this file)
└── BUNDLE_INFO.txt, SHA256SUMS
```

About 5.6 GB in all. Notes:

- **The vg image must be the one pggl-workflow runs.** Every index is built
  with it, and a different vg produces files the per-sample side may refuse
  (`.hapl` v4, GBZ v2). pggl-workflow's own offline bundle carries the same
  image, so the build site may already have it.
- **GRCh38.primary.fa** holds the 25 primary contigs (chr1-22, X, Y, M) of the
  analysis set, sequences untouched. It is the `GRCh38` line of the seqfile and
  the FASTA the extracted reference is M5-checked against. Leaving out the
  decoys, alts and HLA keeps GRCh38 at 25 paths; keeping the sequences keeps
  CRAMs encoded against the analysis set decodable with the graph's reference.
  Without `--grch38` the script downloads the analysis set from 1000 Genomes
  (3.2 GB).
- Downloads and `apptainer pull` run under a shell-level retry
  (`scripts/lib/retry.sh`), because curl 7.68's `--retry` does not cover the
  transient error 56.
- Uncommitted changes are not bundled; the script warns when there are any.
- `--split 20G` splits the `.tar` for media with a file size limit.

## 2. Transfer

Copy the `.tar` (or the `offline-bundle/` directory) to the build site, under
`/home`. After `--split`:

```bash
cat pggl-graph-offline-bundle-20260924.tar.part-* > pggl-graph-offline-bundle-20260924.tar
sha256sum -c pggl-graph-offline-bundle-20260924.tar.sha256
tar xf pggl-graph-offline-bundle-20260924.tar
```

The **input assemblies are not in the bundle**, because they are chosen per
build. Copy them alongside, with a seqfile that names them. GRCh38 must be the
first line and point at `GRCh38.primary.fa`:

```
GRCh38	/home/<user>/pangenome/reference/GRCh38.primary.fa
CHM13	/home/<user>/pangenome/assemblies/chm13v2.0.fa.gz
NA18940.1	/home/<user>/pangenome/assemblies/NA18940.hap1.fa.gz
...
```

## 3. On the build site

```bash
srun -p compute001-006 -c 16 --mem 32G \
    bash offline-bundle/setup-offline.sh --bundle offline-bundle \
        --dest /home/<user>/pangenome --verify
```

This installs:

```
/home/<user>/pangenome/
├── pggl-graph/          the repository, the two SIFs, offline.env
└── reference/           GRCh38.primary.fa (+ M5 sums)
```

`offline.env` records the paths of the images and the reference for the
build scripts:

```bash
. /home/<user>/pangenome/pggl-graph/offline.env
echo "$CACTUS_SIF $VG_SIF $GRCH38_PRIMARY"
```

`--verify` rebuilds the toy release from the checked-in assemblies (Cactus,
then vg) in `/scratch/$USER/pggl-graph-toy`, and passes only when validation
passes and every reproducible file is byte-identical to `tests/toy/expected/`.
Distance and minimizer indexes are exempt, because vg does not build them
deterministically. A pass means that the images, the apptainer setup and the
scripts all work on that site.

## 4. Building

The staged Slurm jobs are not written yet. Until they are, a release can be
built on a single node with the same two steps the toy uses:
`cactus-pangenome --mgSplit`, then `scripts/index-release.sh`. See
`tests/toy/build.sh` for the exact options. `/scratch` is the place for the
Toil work directory, and `TMPDIR` for the vg steps should point there too.

## 5. Bringing a release back

Copy the release directory, with its `graph.manifest.json`, to the shared
filesystem where pggl-workflow runs. File paths in the manifest are relative
to a root that is named per site, so adding the new location is one entry
under `sites`:

```json
"sites": {
  "build":      {"roots": {"release": "/home/<user>/pangenome/releases/<name>"}},
  "nig-lustre": {"roots": {"release": "/lustre10/.../<name>"}}
}
```

Then check it where it now lives:

```bash
python3 scripts/manifest.py check graph.manifest.json --site nig-lustre --md5 --contract
```
