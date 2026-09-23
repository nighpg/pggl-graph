#!/usr/bin/env python3
"""Checks a Minigraph-Cactus seqfile before days of compute are spent on it.

  check-seqfile.py <seqfile> [--reference GRCh38] [--ref-contigs LIST]
                   [--summary out.json] [--absolute out.seqfile]

Refuses what broke JaSaPaGe and what would break pggl-workflow:

  - the reference must be the FIRST entry: Minigraph-Cactus leaves only the
    first --reference unclipped, and build-release.sh passes exactly one
  - its FASTA must hold exactly the expected contigs (default: the 25 GRCh38
    primary contigs, chr1-22, X, Y, M), so the graph gets exactly those paths
    and no decoy/alt/HLA ones
  - sample names must be PanSN-safe (no '#'), the reference without a
    haplotype suffix, every other entry either SAMPLE or SAMPLE.<hap>, and no
    name twice
  - every file must exist and be readable (the build site is offline: no URLs)

--ref-contigs takes a comma-separated list (the toy: chr20,chrX,chrY,chrM).
--summary writes the sample and haplotype counts for the manifest, the
reference FASTA and the directories the inputs live in (to bind into the
container). --absolute writes a copy with every path made absolute, which is
what Cactus is given.
Exit 1 with every problem listed.
"""
import argparse
import gzip
import json
import os
import re
import sys

PRIMARY = ["chr%d" % i for i in range(1, 23)] + ["chrX", "chrY", "chrM"]


def fasta_names(path):
    fai = path + ".fai"
    if not path.endswith(".gz") and os.path.exists(fai):
        return [l.split("\t", 1)[0] for l in open(fai)]
    opener = gzip.open if path.endswith(".gz") else open
    with opener(path, "rt") as f:
        return [l[1:].split()[0] for l in f if l.startswith(">")]


def main():
    p = argparse.ArgumentParser()
    p.add_argument("seqfile")
    p.add_argument("--reference", default="GRCh38")
    p.add_argument("--ref-contigs", default=",".join(PRIMARY))
    p.add_argument("--summary")
    p.add_argument("--absolute")
    a = p.parse_args()

    errs = []
    entries = []
    for n, line in enumerate(open(a.seqfile), 1):
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        f = line.split()
        if len(f) != 2:
            errs.append("line %d: expected '<name> <path>', got %r" % (n, line))
            continue
        path = f[1][len("file://"):] if f[1].startswith("file://") else f[1]
        entries.append((n, f[0], path))
    if not entries:
        sys.exit("check-seqfile.py: %s has no entries" % a.seqfile)

    base = os.path.dirname(os.path.abspath(a.seqfile))
    entries = [(n, name, path if os.path.isabs(path) else os.path.normpath(os.path.join(base, path)))
               for n, name, path in entries]
    names = set()
    samples = set()
    for n, name, path in entries:
        if name in names:
            errs.append("line %d: %s appears twice" % (n, name))
        names.add(name)
        if "#" in name:
            errs.append("line %d: %s contains '#', which PanSN reserves" % (n, name))
        m = re.match(r"^(.+?)(?:\.(\d+))?$", name)
        samples.add(m.group(1))
        if "://" in path:
            errs.append("line %d: %s is a URL; the build site is offline" % (n, path))
            continue
        full = path if os.path.isabs(path) else os.path.join(base, path)
        if not os.access(full, os.R_OK):
            errs.append("line %d: %s not readable" % (n, full))

    n0, first, ref_path = entries[0]
    if first != a.reference:
        where = [n for n, name, _ in entries if name == a.reference]
        errs.append("the first entry is %s, not %s%s. Only the first reference stays whole; "
                    "every later one is clipped into subrange paths (the JaSaPaGe failure)"
                    % (first, a.reference, " (it is on line %d)" % where[0] if where else ""))
    else:
        full = ref_path if os.path.isabs(ref_path) else os.path.join(base, ref_path)
        if os.access(full, os.R_OK):
            want = a.ref_contigs.split(",")
            got = fasta_names(full)
            extra = [c for c in got if c not in want]
            missing = [c for c in want if c not in got]
            if extra:
                errs.append("%s has %d contigs beyond the expected %d (%s%s); they would become "
                            "extra %s paths. Use scripts/grch38-primary.py"
                            % (full, len(extra), len(want), ", ".join(extra[:5]),
                               ", ..." if len(extra) > 5 else "", a.reference))
            if missing:
                errs.append("%s lacks %s" % (full, ", ".join(missing)))
    for n, name, _ in entries[1:]:
        if name.split(".")[0] == a.reference:
            errs.append("line %d: %s again; the reference must appear once, first" % (n, name))

    for e in errs:
        print("ERROR  " + e)
    if errs:
        return 1
    summary = {"reference": a.reference, "samples": len(samples), "haplotypes": len(entries),
               "reference_fasta": entries[0][2],
               "dirs": sorted(set(os.path.dirname(p) for _, _, p in entries))}
    print("OK     %s: %s first, %d samples, %d haplotypes"
          % (a.seqfile, a.reference, summary["samples"], summary["haplotypes"]))
    if a.summary:
        json.dump(summary, open(a.summary, "w"))
    if a.absolute:
        with open(a.absolute, "w") as f:
            for _, name, path in entries:
                f.write("%s\t%s\n" % (name, path))
    return 0


if __name__ == "__main__":
    sys.exit(main())
