# Design

This document records the decisions made so far and the evidence behind each
one. Anything marked **open** has not been decided yet.

## Where it runs

| | Build site | Where JaSaPaGe was indexed |
| --- | --- | --- |
| Network | **air-gapped** | online |
| Slurm partition | `compute001-006` (6 nodes) | various |
| Nodes | 128 CPU / 1031 GB each | various |
| Node-local disk | `/scratch`, 1.5 TB SSD | small `/tmp` |
| Shared filesystem | `/home` | `/lustre10`, `/lustre9` |
| Containers | apptainer | apptainer 1.4.5 |

`/lustre10` is not visible from the build site. Consequences:

- The manifest records paths **relative to the release directory**, plus one
  root per site, never a single absolute path.
- Everything the build needs has to be carried in: the images, this repository
  and the input assemblies. See *Offline*.
- The Slurm partition (`compute001-006`), the shared filesystem root (under
  `/home`) and the scratch directory (`/scratch`) are parameters of every
  sbatch job, not constants: the defaults name the build site, and the toy
  runs anywhere.

## Toolchain

Captured from the image itself in `docs/cactus-v3.3.0-help/versions.txt`:

| | Version |
| --- | --- |
| Cactus | 3.3.0 (`quay.io/comparative-genomics-toolkit/cactus:v3.3.0`) |
| Toil | 9.5.0 |
| vg inside Cactus | v1.76.1-89-gf2ed0bbd4 |
| minigraph | 0.21-r606 |
| vg on the per-sample side | v1.70.0 |

Option names change between Cactus versions. The full `--help` of every
command used here is kept in `docs/cactus-v3.3.0-help/`. Re-capture it when
the image is bumped, and diff it before trusting any existing script.

### The two vg versions do not interoperate

`tests/compat/vg-gbz-compat.sh` gave this result on 2026-09-23:

| Check | Result |
| --- | --- |
| vg 1.70 reads a GBZ written by vg 1.76 | **FAIL**: `GBZ: Expected v1, got v2` |
| vg 1.70 reads a GFA written by vg 1.76 as is | **FAIL**: `GFAFile: duplicate header at line 1` (1.76 adds an `H NM:Z:` line) |
| vg 1.70 reads `.snarls` written by vg 1.76 | pass |
| vg 1.70 builds a GBZ from that GFA with the extra `H` lines dropped, uncompressed | pass; `reference_samples` is kept |
| autoindex, `gbwt -r` and `snarls` with vg 1.70 on that GBZ | pass |

vg 1.70 also fails on a `.gfa.gz` without giving a reason, so the GFA has to be
decompressed first (to `/scratch`).

**Proposed:** one vg version produces *every* file in a release: `gbz`, `dist`,
`min`, `zipcodes`, `ri`, `hapl` and `snarls`. That version is the one the
per-sample side runs. Cactus is used only up to the GFA. The GBZ is rebuilt
from the clip and filter GFAs with the consumer vg
(`vg gbwt -G <gfa> --gbz-format -g`).

Reasons:

- Pangenome-aware DeepVariant 1.10 reads the GBZ itself through its bundled
  gbwtgraph, so vg is not the only GBZ reader. A GBZ v1 is what the whole
  per-sample stack is known to read today.
- It turns "which vg made this file?" into a single field of the manifest
  rather than a per-file puzzle, which is what `.hapl` v4 needed.
- Moving the per-sample side to vg ≥ 1.76 is still possible later. It would
  mean rebuilding and revalidating the DeepVariant images, and it can happen
  independently: a new release would just be indexed with the new vg.

## Pipeline

v3.3.0 has `--mgSplit`, which changes where the parallelism is. Without it,
minigraph construction is a single job that adds every haplotype in turn and
uses the most memory. With it, a reference-only minigraph is used to bin
contigs by chromosome, and construction, mapping and alignment then run
independently for each chromosome.

```
[A] bin          1 job     cactus-minigraph --refOnly
                           cactus-graphmap --mgSplit
                           cactus-graphmap-split --mgSplit
[B] per chrom    array ~25 cactus-minigraph   (chrom seqfile)
                           cactus-graphmap
                           cactus-align --pangenome
[C] join         1 job     cactus-graphmap-join --sv-gfa ... --gfa clip filter
[D] index        vg 1.70, independent jobs
                           clip:   GFA -> gbz, gbwt -r (ri), haplotypes (hapl), snarls
                           filter: GFA -> gbz, autoindex (dist/min/zipcodes), snarls
[E] finish       1 job     vg paths -F -> ref.fa/.fai/.dict, PanSN .dict
                           validate-graph.sh, write graph.manifest.json
```

- Each task in [B] runs Toil with `--batchSystem single_machine`, with the
  jobStore and `--workDir` on `/scratch` and `--binariesMode local`. This
  removes the long-running Toil leader, Toil's multi-node machinery and the
  flood of small files on the shared filesystem. Losing a node loses one
  chromosome's current step, nothing more.
- [B] is split into three arrays (minigraph, graphmap, align) chained with
  `--dependency=aftercorr`. A failed chromosome restarts at its own last step.
- Walltime and memory come from measurements (below), not guesses. An inflated
  walltime blocks backfill.
- `Workflows/build-pangenome.cwl` runs [A]-[E] on one node, for the toy and
  for small builds. Its chromosome scatter runs serially: `cwltool --parallel`
  hands scattered jobs the same temporary output directory and fails with
  `FileExistsError` / exit 127.

### Resource estimates

**Open.** The JaSaPaGe build left no Toil logs, so nothing is measured yet.
Plan: time the toy run, then chr21 (small) and chr1 (large) at full sample
count, and fill in this table from those runs.

| Stage | CPU | Memory | Walltime | `/scratch` |
| --- | --- | --- | --- | --- |
| [A] bin | | | | |
| [B] minigraph (chr1 / chr21) | | | | |
| [B] graphmap (chr1 / chr21) | | | | |
| [B] align (chr1 / chr21) | | | | |
| [C] join | | | | |
| [D] clip index | | | | |
| [D] filter index | | | | |

For scale, JaSaPaGe (134 haplotypes) produced `chr1.hal` 10 GB and `chr1.vg`
6.7 GB.

## Graph content

- **Reference:** `--reference GRCh38` and nothing else. The GRCh38 input is the
  25 primary contigs (chr1-22, X, Y, M) of
  `GRCh38_full_analysis_set_plus_decoy_hla.fa`. This keeps the path count at
  25, and it keeps the sequence (PAR masking included) md5-identical to the
  FASTA the CRAMs were encoded against, so `ref` extracted from the graph can
  decode them.
- **CHM13v2** goes in as an ordinary haplotype sample, not a second reference.
  `reference_samples` then contains GRCh38 alone, and `vg call -S` has nothing
  to choose between.
- **Samples** are chosen for each build; the seqfile is an input and its md5 is
  recorded.
- **Both graphs are released:**
  - clip: `gbz`, `snarls`, `ri`, `hapl`. Used for haplotype sampling and SV
    genotyping; low-frequency SVs stay in the graph.
  - filter (`--filter 2`): `gbz`, `dist`, `min`, `zipcodes`, `snarls`. Used for
    direct mapping; the minimizer index is much smaller.

  `snarls` and `dist` belong to one graph each, so the manifest has one index
  set per graph.

## Manifest

Fixed in the next step, with a hand-written manifest for JaSaPaGe as the first
instance. It records:

- `schema_version`, release name
- Cactus version, image digest, the vg inside Cactus, the `--reference` order,
  the seqfile and its md5, and the build options
- the vg that produced the indexes, and its image digest
- for each file: relative path, size, md5, and producer (tool and version)
- the site roots
- the validation report

## Offline

This follows pggl-workflow's mechanism (`fetch-offline-bundle.sh`,
`setup-offline.sh`, `stage-sif-assets.sh`). The Cactus SIF is 499 MB, and a
vg-only SIF adds a few hundred MB, so the images are small. The input
assemblies dominate the bundle: JaSaPaGe's cleaned assemblies alone are
177 GB. Downloads go through a shell-level retry helper, because curl 7.68's
`--retry` does not cover the transient error 56.

## Copied files

`Tools/vg-autoindex.cwl`, `Tools/vg-snarls.cwl` and
`scripts/prepare_pangenome_indexes.sh` are copies of the pggl-workflow files.
pggl-workflow keeps using them for haplotype sampling. Each copy starts with a
comment naming which repository holds the master copy.
