# pggl-graph

Builds the pangenome graph and index set that
[pggl-workflow](https://github.com/nighpg/pggl-workflow) maps and calls against,
with Minigraph-Cactus. It runs once per pangenome release, whereas pggl-workflow
runs once per sample. The two differ in how often they change, in the compute
they need and in their container images, so they live in separate repositories.

> **Status: skeleton.** The design is in [`docs/DESIGN.md`](docs/DESIGN.md).
> Nothing runs yet.

## What a release must satisfy

A graph is only usable by pggl-workflow when all of these hold. They are
checked by `scripts/validate-graph.sh`, and its report goes into the manifest:

1. PanSN naming, with the reference as a named sample: `GRCh38#0#chr1`, not `chr1`.
2. The GBWT `reference_samples` tag contains `GRCh38` (pggl-workflow's
   `ref_path_prefix: "GRCh38#0#"`).
3. GRCh38 is **25 whole paths** (chr1-22, X, Y, M), and no path name contains `[`.
4. Every index is readable by the **vg the per-sample side uses** (v1.70.0 today).

### Why the order of `--reference` is critical

Minigraph-Cactus leaves **only the first** `--reference` sample unclipped and
does not self-align it. Every other sample, including any later "reference",
is clipped into subrange paths such as `GRCh38#0#chr1[585988]`.

JaSaPaGe listed CHM13v2 first, and its GRCh38 ended up in 166 fragments. That
single choice caused three separate failures downstream:

| Symptom | Cause |
| --- | --- |
| pangenome-aware DeepVariant cannot run on GRCh38 | it resolves a contig name to that contig's first fragment only |
| `vg surject` needs a PanSN `.dict` | a plain path list cannot fold the fragments back into their parent contig |
| `##contig` lengths in the SV VCF are 10-83 kb short | vg reports the end of the last fragment as the contig length |

**GRCh38 therefore goes first, and it is the only reference.** The build
refuses any other order.

## Outputs

These correspond to pggl-workflow's input names:

| pggl-workflow input | Used by | Comes from |
| --- | --- | --- |
| `gbz`, `dist`, `min`, `zipcodes` | `vg giraffe` | filter graph |
| `snarls` | `call_sv` (`vg pack` + `vg call`) | the graph being genotyped |
| `ri`, `hapl` | haplotype sampling | clip graph |
| `ref` (+ `.fai`, `.dict`) | DeepVariant, surject | `vg paths -S GRCh38 -F`, checked by md5 against the linear FASTA |
| `ref_paths` | surject | PanSN `.dict` |
| `ref_path_prefix` | — | `"GRCh38#0#"` |

The files are too large for git or LFS (JaSaPaGe: `min` 38 GB, `dist` 7.6 GB,
`gbz` 3.3 GB). They live in a release directory on the shared filesystem. This
repository keeps only `graph.manifest.json` for each release: relative paths,
sizes, md5 sums, the tool version that produced each file, the build options
and the validation report.

## Layout

```
Tools/        CWL CommandLineTools, one per stage
Workflows/    build-pangenome.cwl (toy and single-node runs)
scripts/      what every Tool and sbatch job actually runs, plus
              validate-graph.sh and prepare_pangenome_indexes.sh
sbatch/       per-stage Slurm jobs for production builds
tests/toy/    a few small FASTAs that run end to end
tests/compat/ cross-version checks between the Cactus and per-sample images
schema/       graph.manifest.schema.json
releases/     one graph.manifest.json per release (JaSaPaGe/ is the first)
docs/         design, resource estimates, offline procedure, captured --help
```

`scripts/` is the source of truth. The CWL Tools and the sbatch jobs both call
the same scripts, so the toy run and the production run execute identical
code.
