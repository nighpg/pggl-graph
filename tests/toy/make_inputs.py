#!/usr/bin/env python3
"""Writes the toy assemblies that tests/toy/build.sh turns into a release.

A 100 kb "GRCh38" (chr20, chrX, chrY, chrM) and seven haplotypes derived from
it, small enough to run Minigraph-Cactus on a laptop in minutes, yet with the
features a real build has to get right:

  - chrY starts with 2 kb of N, like the hard-masked PAR of the GRCh38
    analysis set, so the md5 check of the reference extracted from the graph
    has something to trip over
  - three IUPAC ambiguity codes in GRCh38 (M, R, Y), like the 94 in the real
    primary contigs: vg stores them as N, so the extracted reference differs
    from the source there, and the check must allow exactly that
  - SNPs and small indels in every haplotype, SVs at different frequencies:
    the singleton ones (one haplotype) are what the filter graph drops
  - CHM13 as an ordinary haplotype sample, not a reference
  - a female sample without chrY, an assembly with a contig broken in two,
    and a contig that belongs to no chromosome (it must not end up in the
    GRCh38 paths)

Usage: make_inputs.py <outdir>
Deterministic: the same seed gives byte-identical files.
"""
import gzip
import os
import random
import sys

OUT = sys.argv[1]
rng = random.Random(20260924)
BASES = "ACGT"

CONTIGS = [("chr20", 50000), ("chrX", 30000), ("chrY", 15000), ("chrM", 5000)]
Y_MASK = 2000  # leading N run on chrY


def rand_seq(n):
    return "".join(rng.choice(BASES) for _ in range(n))


ref = {c: rand_seq(n) for c, n in CONTIGS}
ref["chrY"] = "N" * Y_MASK + ref["chrY"][Y_MASK:]

# SVs as (contig, start, kind, length, carriers). Positions are 0-based on the
# reference and far apart so that edits never overlap. Carriers index HAPS.
HAPS = ["CHM13", "S1.1", "S1.2", "S2.1", "S2.2", "S3.1", "S3.2"]
SVS = [
    ("chr20", 8000, "del", 1200, {0, 1, 3, 5}),   # common deletion
    ("chr20", 16000, "ins", 800, {1, 2, 4}),      # common insertion
    ("chr20", 24000, "inv", 1500, {2, 6}),        # inversion, two carriers
    ("chr20", 32000, "del", 300, {4}),            # singleton: gone in filter
    ("chr20", 40000, "ins", 2500, {3}),           # singleton insertion
    ("chrX", 9000, "del", 600, {0, 1, 2, 5, 6}),
    ("chrX", 20000, "ins", 400, {5}),             # singleton
    ("chrY", 7000, "del", 500, {0}),              # CHM13 only
]
# S3 is female: no chrY in S3.1 / S3.2. CHM13 has a chrY here on purpose
# (CHM13v2 carries HG002's Y).
NO_Y = {"S3.1", "S3.2"}
# S2.1's chr20 assembly is broken in two at this reference position
BREAK = ("S2.1", "chr20", 28000)
SV_INS = {i: rand_seq(sv[3]) for i, sv in enumerate(SVS) if sv[2] == "ins"}


def revcomp(s):
    return s[::-1].translate(str.maketrans("ACGTN", "TGCAN"))


def haplotype(h, contig):
    """Apply the SVs this haplotype carries, then point mutations, from right
    to left so earlier positions stay valid."""
    s = ref[contig]
    for i, (c, pos, kind, n, carriers) in sorted(
            enumerate(SVS), key=lambda x: -x[1][1]):
        if c != contig or HAPS.index(h) not in carriers:
            continue
        if kind == "del":
            s = s[:pos] + s[pos + n:]
        elif kind == "ins":
            s = s[:pos] + SV_INS[i] + s[pos:]
        else:
            s = s[:pos] + revcomp(s[pos:pos + n]) + s[pos + n:]
    out = []
    i = 0
    while i < len(s):
        b = s[i]
        r = rng.random()
        if b != "N" and r < 1 / 400:          # SNP
            out.append(rng.choice([x for x in BASES if x != b]))
        elif b != "N" and r < 1 / 400 + 1 / 3000:   # small deletion
            i += rng.randint(1, 8)
            continue
        elif b != "N" and r < 1 / 400 + 2 / 3000:   # small insertion
            out.append(b + rand_seq(rng.randint(1, 8)))
        else:
            out.append(b)
        i += 1
    return "".join(out)


def write_fasta(path, records):
    with gzip.GzipFile(path, "wb", mtime=0) as f:
        for name, seq in records:
            f.write((">%s\n" % name).encode())
            for i in range(0, len(seq), 80):
                f.write((seq[i:i + 80] + "\n").encode())


# IUPAC codes go into the written reference only, after every random draw,
# so the haplotypes (derived from the plain bases) and the rest of the inputs
# do not change
IUPAC = [("chr20", 12345, "M"), ("chr20", 36789, "R"), ("chrX", 15000, "Y")]
written = dict(ref)
for c, pos, code in IUPAC:
    written[c] = written[c][:pos] + code + written[c][pos + 1:]

os.makedirs(OUT, exist_ok=True)
write_fasta(os.path.join(OUT, "GRCh38.fa.gz"), [(c, written[c]) for c, _ in CONTIGS])
seqfile = ["GRCh38\tGRCh38.fa.gz"]
for h in HAPS:
    recs = []
    k = 0
    for c, _ in CONTIGS:
        if c == "chrY" and h in NO_Y:
            continue
        s = haplotype(h, c)
        # assemblies do not know chromosome names
        if (h, c) == BREAK[:2]:
            cut = BREAK[2]
            pieces = [s[:cut], s[cut:]]
        else:
            pieces = [s]
        for p in pieces:
            k += 1
            recs.append(("%s_ctg%d" % (h.replace(".", "_"), k), p))
    if h == "S1.2":
        recs.append(("S1_2_ctg_unplaced", rand_seq(6000)))
    fn = "%s.fa.gz" % h
    write_fasta(os.path.join(OUT, fn), recs)
    seqfile.append("%s\t%s" % (h, fn))
with open(os.path.join(OUT, "seqfile.txt"), "w") as f:
    f.write("\n".join(seqfile) + "\n")
