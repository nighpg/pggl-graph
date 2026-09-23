#!/usr/bin/env python3
"""Judges the raw outputs that validate-graph.sh collects from vg.

Each subcommand prints one line, "<pass|fail>\t<detail>", which
validate-graph.sh records as a check result; `report` assembles the results
into the manifest's validation block.

  expected   <pansn.dict> <prefix> <fai|->        -> expected.tsv on stdout
  lengths    <expected.tsv> <paths.tsv> <prefix>   (vg paths -E output)
  sam        <expected.tsv> <in.sam> <prefix>
  report     <checks.tsv> <vg_version> <validator> <graph>
"""
import datetime
import json
import sys


def read_expected(path):
    exp = {}
    order = []
    for line in open(path):
        c, n = line.rstrip("\n").split("\t")
        exp[c] = int(n)
        order.append(c)
    return exp, order


def cmd_expected(dict_path, prefix, fai_path):
    """Contigs and lengths the release promises, from the PanSN .dict, with
    the lengths cross-checked against the linear FASTA's .fai."""
    exp = []
    for line in open(dict_path):
        if not line.startswith("@SQ"):
            continue
        f = dict(x.split(":", 1) for x in line.rstrip("\n").split("\t")[1:])
        sn = f["SN"]
        if not sn.startswith(prefix):
            sys.exit("expected: %s in %s lacks the prefix %s" % (sn, dict_path, prefix))
        exp.append((sn[len(prefix):], int(f["LN"])))
    if fai_path != "-":
        fai = {}
        for line in open(fai_path):
            c, n = line.split("\t")[:2]
            fai[c] = int(n)
        bad = [c for c, n in exp if fai.get(c) != n]
        if bad:
            sys.exit("expected: .dict and .fai disagree on %s" % ", ".join(bad))
    for c, n in exp:
        print("%s\t%d" % (c, n))


def cmd_lengths(exp_path, paths_path, prefix):
    exp, order = read_expected(exp_path)
    whole = {}
    frags = {}
    extra = []
    for line in open(paths_path):
        name, n = line.rstrip("\n").split("\t")[:2]
        n = int(n)
        base = name[len(prefix):] if name.startswith(prefix) else name
        contig = base.split("[", 1)[0]
        if contig not in exp:
            extra.append(name)
        elif "[" in base:
            frags.setdefault(contig, []).append(n)
        else:
            whole[contig] = n
    # A clipped contig whose first piece starts at 0 keeps the plain name, so a
    # "whole" path alongside fragments is just the first fragment.
    for c in list(whole):
        if c in frags:
            frags[c].append(whole.pop(c))
    problems = []
    for c in order:
        if c in whole:
            if whole[c] != exp[c]:
                problems.append("%s %d bp, expected %d" % (c, whole[c], exp[c]))
        elif c in frags:
            got = sum(frags[c])
            problems.append("%s only as %d fragments covering %d of %d bp (%.1f%%)"
                            % (c, len(frags[c]), got, exp[c], 100.0 * got / exp[c]))
        else:
            problems.append("%s missing" % c)
    if extra:
        problems.append("%d paths outside the expected contigs (%s%s)"
                        % (len(extra), ", ".join(extra[:3]), ", ..." if len(extra) > 3 else ""))
    if problems:
        shown = "; ".join(problems[:6])
        more = " (+%d more)" % (len(problems) - 6) if len(problems) > 6 else ""
        print("fail\t%d of %d contigs whole with matching length; %s%s"
              % (sum(1 for c in order if whole.get(c) == exp[c]), len(order), shown, more))
    else:
        print("pass\tall %d contigs are whole paths with the .fai length" % len(order))


def cmd_sam(exp_path, sam_path, prefix):
    exp, order = read_expected(exp_path)
    sq = []
    reads = mapped = 0
    off_target = set()
    for line in open(sam_path):
        if line.startswith("@SQ"):
            f = dict(x.split(":", 1) for x in line.rstrip("\n").split("\t")[1:])
            sq.append((f["SN"], int(f["LN"])))
        elif not line.startswith("@"):
            t = line.split("\t", 4)
            flag = int(t[1])
            if flag & 0x900:  # secondary / supplementary
                continue
            reads += 1
            if not flag & 0x4:
                mapped += 1
                if t[2] not in [prefix + c for c in order]:
                    off_target.add(t[2])
    problems = []
    names = [n for n, _ in sq]
    if len(sq) != len(order):
        problems.append("%d @SQ lines, expected %d" % (len(sq), len(order)))
    frag = [n for n in names if "[" in n]
    if frag:
        problems.append("%d @SQ are fragment names (%s)" % (len(frag), frag[0]))
    bad = [(n, l) for n, l in sq
           if not n.startswith(prefix) or exp.get(n[len(prefix):]) != l]
    if bad and not frag:
        problems.append("@SQ not matching %s<contig> with the .fai length: %s"
                        % (prefix, ", ".join("%s:%d" % b for b in bad[:3])))
    if reads == 0:
        problems.append("no reads in the output")
    elif mapped < 0.9 * reads:
        problems.append("only %d of %d reads placed on the reference" % (mapped, reads))
    if off_target:
        problems.append("reads placed on %s" % ", ".join(sorted(off_target)[:3]))
    head = "%d @SQ, %d/%d reads placed" % (len(sq), mapped, reads)
    if problems:
        print("fail\t%s; %s" % (head, "; ".join(problems)))
    else:
        print("pass\t%s; every @SQ is %s<contig> with the .fai length" % (head, prefix))


def cmd_report(checks_path, vg_version, validator, graph):
    checks = []
    for line in open(checks_path):
        cid, name, status, detail = line.rstrip("\n").split("\t", 3)
        checks.append({"id": cid, "name": name, "status": status, "detail": detail})
    status = "fail" if any(c["status"] == "fail" for c in checks) else "pass"
    if not checks:
        status = "not_run"
    rep = {
        "status": status,
        "date": datetime.date.today().isoformat(),
        "validator": validator,
        "vg_version": vg_version,
        "graph": graph or None,
        "checks": checks,
        "report": None,
    }
    json.dump(rep, sys.stdout, indent=2)
    print()


if __name__ == "__main__":
    cmd, args = sys.argv[1], sys.argv[2:]
    {"expected": cmd_expected, "lengths": cmd_lengths,
     "sam": cmd_sam, "report": cmd_report}[cmd](*args)
