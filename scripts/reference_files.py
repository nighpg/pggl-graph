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

With a source FASTA, every graph contig must be in it with the same M5 (md5
of the upper-cased sequence, as in a sequence dictionary and in CRAM). The
source may hold more contigs (decoys, alts); those are listed, not errors.
Exit 1 on any mismatch.

The M5 sums also go into both .dict files. That is what lets a FASTA that
holds more than the reference contigs -- the full analysis set the CRAMs were
encoded against -- be checked and used as pggl-workflow's ref for CRAM input
(manifest.py job --cram-reference). <outprefix>.fa itself cannot decode a CRAM
that has reads on decoy, HLA or alt contigs: htslib needs every contig a CRAM
refers to.
"""
import gzip
import hashlib
import sys


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
        src_m5 = {}
        for name, seq in read_fasta(source):
            src_order.append(name)
            src_m5[name] = (len(seq), m5(seq))
        order = [c for c in src_order if c in graph]
        for c in graph_order:
            if c not in src_m5:
                print("FAIL  %s: not in %s" % (c, source))
                fail += 1
                continue
            n, h = src_m5[c]
            if (n, h) != (len(graph[c]), m5(graph[c])):
                print("FAIL  %s: graph %d bp M5 %s, source %d bp M5 %s"
                      % (c, len(graph[c]), m5(graph[c]), n, h))
                fail += 1
            else:
                print("OK    %s %d bp M5 %s" % (c, n, h))
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
