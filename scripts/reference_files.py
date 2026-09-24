#!/usr/bin/env python3
"""Turns the reference paths extracted from a graph into pggl-workflow's
reference inputs, and checks them against the linear FASTA they came from.

  reference_files.py <graph-ref.fa> <path_prefix> <outprefix> [source.fa[.gz]]

<graph-ref.fa> is `vg paths -x <gbz> -S <sample> -F`, with PanSN names.
Writes:
  <outprefix>.fa          plain contig names (chr1, ...): pggl-workflow's ref
  <outprefix>.fa.fai
  <outprefix>.dict        SN:<contig>, LN, M5
  <outprefix>.pansn.dict  SN:<path_prefix><contig>, LN, M5: pggl-workflow's
                          ref_paths
Contigs keep the source FASTA's order when one is given (so chr1..chr22, X, Y,
M rather than whatever order the graph stores), the graph's order otherwise.

With a source FASTA, every graph contig must be in it with the same sequence,
compared by M5 (md5 of the upper-cased sequence, as in a sequence dictionary
and in CRAM), except that IUPAC ambiguity codes in the source (M, R, Y, ...)
are N in the graph: vg stores only A, C, G, T and N, and Minigraph-Cactus
converts them. GRCh38's primary contigs carry 94 such codes (3 of them on
chr21), so 14 of its 25 contigs never match as they are; they are compared
with the codes turned into N, and the number of codes is reported. The
source may hold more contigs (decoys, alts); those are listed, not errors.
Exit 1 on any other difference. <outprefix>.source-check.tsv records, per
contig, the length, the source's M5, the graph's M5 and the codes that became N.

The M5 sums also go into both .dict files. That is what lets a FASTA that
holds more than the reference contigs -- the full analysis set the CRAMs were
encoded against -- be checked and used as pggl-workflow's ref for CRAM input
(manifest.py job --cram-reference). <outprefix>.fa itself cannot decode a CRAM
that has reads on decoy, HLA or alt contigs: htslib needs every contig a CRAM
refers to.
"""
import gzip
import hashlib
import re
import sys

NOT_ACGTN = re.compile("[^ACGTN]")


def read_fasta(path):
    opener = gzip.open if path.endswith(".gz") else open
    name, buf = None, []
    with opener(path, "rt") as f:
        for line in f:
            line = line.rstrip("\n")
            if line.startswith(">"):
                if name is not None:
                    yield name, "".join(buf)
                name, buf = line[1:].split()[0], []
            else:
                buf.append(line)
    if name is not None:
        yield name, "".join(buf)


def m5(seq):
    return hashlib.md5(seq.upper().encode()).hexdigest()


def as_stored(seq):
    """The sequence as vg stores it: upper case, IUPAC codes as N.
    Returns it and the number of codes turned into N."""
    return NOT_ACGTN.subn("N", seq.upper())


def main(graph_fa, prefix, out, source=None):
    graph = {}
    graph_order = []
    for name, seq in read_fasta(graph_fa):
        if not name.startswith(prefix):
            sys.exit("reference_files.py: %s lacks the prefix %s" % (name, prefix))
        c = name[len(prefix):]
        if "[" in c:
            sys.exit("reference_files.py: %s is a fragment; the reference must be whole paths" % name)
        graph[c] = seq
        graph_order.append(c)

    order = graph_order
    fail = 0
    if source:
        src_order = []
        src = {}   # contig -> (length, M5 as is, M5 as vg stores it, IUPAC codes)
        for name, seq in read_fasta(source):
            src_order.append(name)
            if name in graph:
                stored, k = as_stored(seq)
                src[name] = (len(seq), m5(seq), m5(stored), k)
            else:
                src[name] = None
        order = [c for c in src_order if c in graph]
        check = open(out + ".source-check.tsv", "w")
        check.write("contig\tlength\tsource_m5\tgraph_m5\tiupac_as_n\n")
        for c in graph_order:
            if src.get(c) is None:
                print("FAIL  %s: not in %s" % (c, source))
                fail += 1
                continue
            n, h_src, h_stored, k = src[c]
            h_graph = m5(graph[c])
            check.write("%s\t%d\t%s\t%s\t%d\n" % (c, n, h_src, h_graph, k))
            if n != len(graph[c]) or h_stored != h_graph:
                print("FAIL  %s: graph %d bp M5 %s, source %d bp M5 %s (%s with IUPAC codes as N)"
                      % (c, len(graph[c]), h_graph, n, h_src, h_stored))
                fail += 1
            elif k:
                print("OK    %s %d bp M5 %s; the source's %d IUPAC code(s) are N in the graph "
                      "(source M5 %s)" % (c, n, h_graph, k, h_src))
            else:
                print("OK    %s %d bp M5 %s" % (c, n, h_graph))
        check.close()
        extra = [c for c in src_order if c not in graph]
        if extra:
            print("note  %d source contigs are not reference paths of the graph (%s%s)"
                  % (len(extra), ", ".join(extra[:5]), ", ..." if len(extra) > 5 else ""))

    with open(out + ".fa", "w") as fa, open(out + ".fa.fai", "w") as fai:
        offset = 0
        for c in order:
            s = graph[c]
            head = ">%s\n" % c
            offset += len(head)
            fai.write("%s\t%d\t%d\t60\t61\n" % (c, len(s), offset))
            fa.write(head)
            for i in range(0, len(s), 60):
                fa.write(s[i:i + 60] + "\n")
            offset += len(s) + (len(s) + 59) // 60
    for path, p in [(out + ".dict", ""), (out + ".pansn.dict", prefix)]:
        with open(path, "w") as d:
            d.write("@HD\tVN:1.6\tSO:unsorted\n")
            for c in order:
                d.write("@SQ\tSN:%s%s\tLN:%d\tM5:%s\n" % (p, c, len(graph[c]), m5(graph[c])))
    print("wrote %s.fa/.fa.fai/.dict/.pansn.dict (%d contigs)" % (out, len(order)))
    return 1 if fail else 0


if __name__ == "__main__":
    if len(sys.argv) not in (4, 5):
        sys.exit(__doc__)
    sys.exit(main(*sys.argv[1:]))
