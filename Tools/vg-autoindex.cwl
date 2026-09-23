#!/usr/bin/env cwl-runner

# COPY -- the master is nighpg/pggl-workflow Tools/vg-autoindex.cwl (copied at 6738d0e).
# Change it there first, then copy it here again; never edit only this copy.

class: CommandLineTool
id: vg-autoindex
label: vg autoindex (giraffe index set for a graph)
cwlVersion: v1.1

doc: |
  Builds the distance, minimizer and zipcode indexes a graph needs before
  `vg giraffe` can map to it.

  scripts/prepare_pangenome_indexes.sh cannot be used for a sampled graph: it
  also derives a ref_paths list from full-length reference paths, and a sampled
  graph keeps its reference as subranges, so it stops with "only N full-length
  paths". ref_paths is unaffected by sampling anyway and is reused unchanged.

requirements:
  InlineJavascriptRequirement: {}
  InitialWorkDirRequirement:
    listing:
      - class: File
        location: ../scripts/vg-autoindex.sh
        basename: vg-autoindex.sh

hints:
  DockerRequirement:
    dockerPull: quay.io/vgteam/vg:v1.70.0

baseCommand: [bash, vg-autoindex.sh]

inputs:
  gbz:
    type: File
    doc: Graph to index
    inputBinding:
      position: 1

  prefix:
    type: string
    doc: Output file prefix; produces <prefix>.dist / .min / .zipcodes
    inputBinding:
      position: 2

  threads:
    type: int
    default: 16
    inputBinding:
      position: 3

  target_mem:
    type: string?
    doc: Memory budget for vg autoindex (-M, e.g. 80G). vg otherwise sizes it from what it sees on the machine, which ignores the limit of a batch job.
    inputBinding:
      position: 4

outputs:
  dist:
    type: File
    doc: giraffe distance index
    outputBinding:
      glob: $(inputs.prefix).dist

  min:
    type: File
    doc: giraffe minimizer index (renamed from vg's shortread.withzip.min)
    outputBinding:
      glob: $(inputs.prefix).min

  zipcodes:
    type: File
    doc: giraffe zipcode index (renamed from vg's shortread.zipcodes)
    outputBinding:
      glob: $(inputs.prefix).zipcodes
