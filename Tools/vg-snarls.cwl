#!/usr/bin/env cwl-runner

# COPY -- the master is nighpg/pggl-workflow Tools/vg-snarls.cwl (copied at 6738d0e).
# Change it there first, then copy it here again; never edit only this copy.

class: CommandLineTool
id: vg-snarls
label: vg snarls (for the call_sv track)
cwlVersion: v1.1

doc: |
  Snarls for a graph, consumed only by the germline workflows' call_sv track.
  A sampled graph needs its own: the snarls shipped with the full graph describe
  sites sampling may have removed.

  Produces no output when make_snarls is false, which is how this workflow
  expresses "off" (cwlVersion v1.1 has no conditional steps).

requirements:
  InlineJavascriptRequirement: {}
  InitialWorkDirRequirement:
    listing:
      - class: File
        location: ../scripts/vg-snarls.sh
        basename: vg-snarls.sh

hints:
  DockerRequirement:
    dockerPull: quay.io/vgteam/vg:v1.70.0

baseCommand: [bash, vg-snarls.sh]

inputs:
  gbz:
    type: File
    doc: Graph to compute snarls for
    inputBinding:
      position: 1

  prefix:
    type: string
    doc: Output file prefix; produces <prefix>.snarls
    inputBinding:
      position: 2

  threads:
    type: int
    default: 16
    inputBinding:
      position: 3

  make_snarls:
    type: boolean
    doc: Compute the snarls. Off by default because they are only needed for call_sv and are expensive on a whole-genome graph.
    default: false

arguments:
  - position: 4
    valueFrom: '$(inputs.make_snarls ? "true" : "false")'

outputs:
  snarls:
    type: File?
    doc: Snarls for the call_sv track (null when make_snarls is false)
    outputBinding:
      glob: $(inputs.prefix).snarls
