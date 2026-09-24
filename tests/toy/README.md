# Toy release

A complete release built from synthetic assemblies. It has every file a real
release has, a manifest, and a validation that passes, and it is small enough
to check in (about 2 MB). It serves three purposes:

- the end-to-end test of this repository: assemblies → Cactus → vg 1.70
  indexes → manifest → `validate-graph.sh`
- the reference that the staged pipeline (`sbatch/`, `Workflows/`) must
  reproduce
- a toy input for pggl-workflow built the way real graphs are, unlike its own
  `tests/toy/`, which is `vg autoindex` from a VCF

## Contents

`input/` is written by `make_inputs.py` (deterministic, seed fixed):

| Haplotype | What it exercises |
| --- | --- |
| `GRCh38` | the only `--reference`: chr20 50 kb, chrX 30 kb, chrY 15 kb (first 2 kb N, like the masked PAR), chrM 5 kb; three IUPAC codes, like the 94 in the real primary contigs |
| `CHM13` | an ordinary haplotype sample, not a second reference |
| `S1.1`, `S1.2` | `S1.2` has a 6 kb contig that belongs to no chromosome |
| `S2.1`, `S2.2` | `S2.1` has chr20 broken into two contigs |
| `S3.1`, `S3.2` | female: no chrY |

Every haplotype carries SNPs and small indels (independent per haplotype) and
some of eight SVs: deletions, insertions and an inversion, carried by one to
five haplotypes.

`expected/` is the release, as `tests/toy/build.sh` leaves it:
`toy.{clip,filter}.*`, `toy.ref.*`, `toy.seqfile.txt`, `graph.manifest.json`
(site `toy`, root `.`, so it stays valid wherever the repository is cloned) and
`validation.log`.

## What a correct build shows

- `validate-graph.sh` passes every check on both graphs (see `validation.log`).
- GRCh38 is 4 whole paths, and the reference extracted from the graph is
  identical to `input/GRCh38.fa.gz`, N run included, except at the three IUPAC
  codes (M, R, Y), which vg stores as N. `toy.ref.source-check.tsv` lists both
  M5 sums per contig, and the manifest records `iupac_as_n: 3`.
- Cactus writes `toy.WARNING` about `S1_2_ctg_unplaced` (6000 bp in no graph).
  That is the intended outcome for a contig that maps to no chromosome, not a
  fault.
- The filter graph (`--filter 2`) is shorter (about 100.8 kb against 107.9 kb)
  and has far fewer snarls. Because the toy's SNPs are private to one
  haplotype, filtering drops them all, and the haplotype paths of the filter
  graph come in dozens of pieces each. Real data has fewer private variants,
  but the effect is the same in kind: this is why haplotype sampling uses the
  clip graph.

## Reproducibility

Three builds (at `--maxCores` 4 and 16, one of them with networking disabled)
gave byte-identical GBZs, reference files, `ri`, `hapl`, `zipcodes` and snarls.
The distance indexes of both graphs and the filter graph's `min` differ from
build to build, because vg's index construction is not deterministic across
threads. The manifest's md5 sums therefore identify *these* files; they do not
predict what a rebuild will produce. `validate-graph.sh` judges a rebuild by
content.

## Offline

The whole build runs without a network. `unshare -rn tests/toy/build.sh ...`
(a user namespace with only a loopback interface) passes every check with
Cactus in `--binariesMode local` and vg from the per-sample image; nothing is
fetched. That run took 3 minutes against 12 for the same 332 Toil jobs online.
The cause was not established: the Toil log shows no network waits.

## The multi-node build

`TOY_BUILD=staged` builds the toy with `scripts/build-staged.sh`, stage by
stage on one host, as the Slurm chain would: bin, every chromosome task plus
one past the last (which must do nothing), join, index. With `TOY_MODE=check`
it has to match `expected/` like the one-node build, and it does: all 13
reproducible files are identical. The same chain was also submitted to Slurm
with `scripts/submit-staged.sh --shared`. The four chromosome tasks ran at the
same time, and the release again matched byte for byte.

```bash
TOY_BUILD=staged TOY_MODE=check tests/toy/build.sh cactus_v3.3.0.sif <vg-1.70.sif> [workdir]
```

## Rebuilding

```bash
python3 tests/toy/make_inputs.py tests/toy/input     # only if the generator changed
THREADS=16 tests/toy/build.sh cactus_v3.3.0.sif <vg-1.70.sif> [workdir]
```

The Cactus step takes 10-20 minutes, almost all of it Toil's per-job overhead;
the vg step takes seconds. The exit status is `validate-graph.sh`'s: 0 when
every check passes.

## Using it from pggl-workflow

```bash
python3 scripts/manifest.py job tests/toy/expected/graph.manifest.json --site toy
```

This prints `gbz`, `dist`, `min`, `zipcodes`, `snarls`, `ref`, `ref_paths` and
`ref_path_prefix` for a job file. Reads still have to be simulated against
`toy.ref.fa`.
