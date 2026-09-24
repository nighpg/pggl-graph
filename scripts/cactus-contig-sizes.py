#!/usr/bin/env python3
"""Writes <name>.input-contig-sizes.tsv.gz, the baseline of Cactus's exclusion
report, for a build that does not run cactus-pangenome end to end.

  cactus-contig-sizes.py <seqfile> <out.tsv.gz> [processes]

cactus-pangenome makes this table itself, from the input FASTAs right after
sanitizing their headers, and hands it to the join; the join then says how
much of each genome reached no graph (<name>.WARNING, <name>.stats/). The
staged build runs cactus-graphmap-join on its own, which only reports that
when given the table (--inputContigSizes). This makes the same table the same
way: every FASTA goes through cactus_sanitizeFastaHeaders exactly as
cactus-pangenome runs it (`gzip -dc <fa> | cactus_sanitizeFastaHeaders - <event> -p`),
and the rows are built and written by Cactus's own functions. Run it inside the
Cactus image, whose cactus package it imports.

One process per genome (default: as many as there are CPUs).
"""
import gzip
import os
import shlex
import subprocess
import sys
import tempfile
from multiprocessing import Pool

from cactus.refmap.pangenome_exclusions import contig_sizes_from_fai, write_baseline_tsv


def read_seqfile(path):
    for line in open(path):
        f = line.split()
        if len(f) == 2 and not line.startswith("#") and not f[0].startswith("("):
            yield f[0], f[1][len("file://"):] if f[1].startswith("file://") else f[1]


def sizes(args):
    event, path = args
    cmd = "gzip -dcf %s | cactus_sanitizeFastaHeaders - %s -p" % (shlex.quote(path), shlex.quote(event))
    proc = subprocess.Popen(cmd, shell=True, stdout=subprocess.PIPE, universal_newlines=True,
                            executable="/bin/bash")
    lengths = []
    name, n = None, 0
    for line in proc.stdout:
        if line.startswith(">"):
            if name is not None:
                lengths.append((name, n))
            name, n = line[1:].split()[0], 0
        else:
            n += len(line.rstrip("\n"))
    if name is not None:
        lengths.append((name, n))
    if proc.wait() != 0:
        raise RuntimeError("failed: " + cmd)
    # contig_sizes_from_fai reads the first two columns of a faidx index
    with tempfile.NamedTemporaryFile("w", suffix=".fai", delete=False) as fai:
        for name, n in lengths:
            fai.write("%s\t%d\n" % (name, n))
    try:
        return contig_sizes_from_fai(fai.name, event)
    finally:
        os.unlink(fai.name)


def main(seqfile, out, processes=None):
    entries = sorted(read_seqfile(seqfile))
    with Pool(int(processes) if processes else None) as pool:
        per_event = pool.map(sizes, entries)
    rows = [r for event_rows in per_event for r in event_rows]
    write_baseline_tsv(rows, out)
    print("%s: %d contigs over %d genomes, %d bp"
          % (out, len(rows), len(entries), sum(r[4] for r in rows)))


if __name__ == "__main__":
    if len(sys.argv) not in (3, 4):
        sys.exit(__doc__)
    main(*sys.argv[1:])
