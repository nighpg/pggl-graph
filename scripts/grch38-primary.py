#!/usr/bin/env python3
"""Writes the GRCh38 that goes into a build: the 25 primary contigs (chr1-22,
X, Y, M) of a full GRCh38 FASTA, sequences untouched.

  grch38-primary.py <GRCh38 FASTA[.gz]> <out.fa>

The decoys, alts, HLA and EBV contigs do not belong in the graph: in the
seqfile they would become extra GRCh38 paths. The 25 are taken from
GRCh38_full_analysis_set_plus_decoy_hla.fa (the FASTA the CRAMs are encoded
against), which keeps them M5-identical to it, PAR masking included. That full
FASTA can then stand in for the graph's reference wherever more contigs are
needed, which is the case for decoding a CRAM (see manifest.py job
--cram-reference). Contigs are written in the source's order, 60 bases per
line, and a line per contig with its length and M5 goes to stderr.

Exit 1 when any of the 25 is missing.
"""
import gzip
import hashlib
import sys

WANT = ["chr%d" % i for i in range(1, 23)] + ["chrX", "chrY", "chrM"]


def main(src, out):
    opener = gzip.open if src.endswith(".gz") else open
    found = []
    keep = False
    buf = []

    def flush(name):
        seq = "".join(buf)
        for i in range(0, len(seq), 60):
            fo.write(seq[i:i + 60] + "\n")
        sys.stderr.write("%s\t%d\t%s\n" % (name, len(seq),
                                           hashlib.md5(seq.upper().encode()).hexdigest()))

    with opener(src, "rt") as fi, open(out, "w") as fo:
        name = None
        for line in fi:
            if line.startswith(">"):
                if keep:
                    flush(name)
                name = line[1:].split()[0]
                keep = name in WANT
                buf = []
                if keep:
                    found.append(name)
                    fo.write(">%s\n" % name)
            elif keep:
                buf.append(line.rstrip("\n"))
        if keep:
            flush(name)
    missing = [c for c in WANT if c not in found]
    if missing:
        sys.exit("grch38-primary.py: missing from %s: %s" % (src, ", ".join(missing)))


if __name__ == "__main__":
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    main(*sys.argv[1:])
