#!/usr/bin/env python3
"""Writes graph.manifest.json for a release directory built by this repository.

The release directory is flat, with this layout (the one place it is defined):

  <name>.<graph>.gbz / .dist / .min / .zipcodes / .snarls / .ri / .hapl
                                   one set per graph (clip, filter)
  <name>.ref.fa / .ref.fa.fai / .ref.dict / .ref.pansn.dict
  <name>.seqfile.txt               the seqfile the graph was built from

Everything that can be read off the files is: sizes, md5 sums, vg format
versions (vg describe), the GBWT reference_samples tag and haplotype count,
the reference path count. What cannot -- how the graph was built -- comes from
--build-info, a JSON object with the manifest's `build` fields (cactus_version,
cactus_image, reference_order, options, ...). vg must be on PATH, and it must
be the vg that built the indexes: its version is recorded as their producer.

Usage:
  write-manifest.py --release-dir DIR --name NAME --release LABEL
                    --site SITE [--site-root DIR] --build-info build.json
                    [--index-image-ref REF --index-image-sha256 HEX]
                    [--source-fasta PATH] [--roles giraffe=filter,...]
                    [--description TEXT] -o graph.manifest.json

--site-root is what the site's "release" root points at (default: the release
directory as given; a relative value is resolved against the manifest's own
directory, which is how the checked-in toy stays relocatable).
"""
import argparse
import hashlib
import json
import os
import re
import subprocess
import sys

GRAPH_KEYS = ["gbz", "dist", "min", "zipcodes", "snarls", "ri", "hapl"]
REF_SAMPLE = "GRCh38"
REF_PREFIX = "GRCh38#0#"


def md5sum(path, bufsize=1 << 24):
    h = hashlib.md5()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(bufsize), b""):
            h.update(chunk)
    return h.hexdigest()


def vg(*args):
    return subprocess.check_output(("vg",) + args, stderr=subprocess.DEVNULL).decode()


def format_version(path):
    m = re.search(r"^\s+Version (\d+)", vg("describe", path), re.M)
    return int(m.group(1)) if m else None


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--release-dir", required=True)
    p.add_argument("--name", required=True)
    p.add_argument("--release", required=True)
    p.add_argument("--site", required=True)
    p.add_argument("--site-root")
    p.add_argument("--build-info", required=True)
    p.add_argument("--index-image-ref")
    p.add_argument("--index-image-sha256")
    p.add_argument("--source-fasta")
    p.add_argument("--roles", default="")
    p.add_argument("--description")
    p.add_argument("-o", "--output", required=True)
    a = p.parse_args()

    R = a.release_dir
    vg_version = vg("version").splitlines()[0].split()[2]
    producer_vg = {"tool": "vg", "version": vg_version}

    def entry(fn, producer, fmt=False, note=None):
        full = os.path.join(R, fn)
        e = {"root": "release", "path": fn, "size": os.stat(full).st_size,
             "md5": md5sum(full), "producer": producer}
        if fmt:
            v = format_version(full)
            if v is not None:
                e["format_version"] = v
        if note:
            e["note"] = note
        return e

    graphs = {}
    for g in ["full", "clip", "filter"]:
        files = {}
        for k in GRAPH_KEYS:
            fn = "%s.%s.%s" % (a.name, g, k)
            if os.path.exists(os.path.join(R, fn)):
                files[k] = entry(fn, producer_vg, fmt=k in ("gbz", "min", "ri", "hapl"))
        if not files:
            continue
        if "gbz" not in files:
            sys.exit("write-manifest.py: %s graph has indexes but no gbz" % g)
        gbz = os.path.join(R, files["gbz"]["path"])
        tags = dict(l.split("\t", 1) for l in vg("gbwt", "-Z", gbz, "--tags").splitlines() if "\t" in l)
        files["reference_samples"] = tags.get("reference_samples", "").split()
        files["haplotypes"] = int(vg("gbwt", "-Z", gbz, "-H").strip())
        graphs[g] = files
    if not graphs:
        sys.exit("write-manifest.py: no <name>.<graph>.gbz in %s" % R)

    # the reference, judged on the graph that serves giraffe
    roles = {}
    if "filter" in graphs and "min" in graphs["filter"]:
        roles["giraffe"] = "filter"
    elif "clip" in graphs and "min" in graphs["clip"]:
        roles["giraffe"] = "clip"
    for g in ["clip", "full"]:
        if g in graphs and "hapl" in graphs[g]:
            roles["haplotype_sampling"] = g
            break
    for g in ["clip", "full", "filter"]:
        if g in graphs and "snarls" in graphs[g]:
            roles["call_sv"] = g
            break
    if "giraffe" in roles:
        roles["pangenome_aware_dv"] = roles["giraffe"]  # the GBZ the reads were mapped to
    for kv in filter(None, a.roles.split(",")):
        k, v = kv.split("=")
        roles[k] = v

    ref_graph = roles.get("giraffe", sorted(graphs)[0])
    ref_paths = vg("paths", "-x", os.path.join(R, graphs[ref_graph]["gbz"]["path"]),
                   "-S", REF_SAMPLE, "-L").split()
    n_frag = sum("[" in x for x in ref_paths)
    pansn = entry("%s.ref.pansn.dict" % a.name, {"tool": "pggl-graph reference_files.py", "version": None})
    contigs = sum(1 for l in open(os.path.join(R, pansn["path"])) if l.startswith("@SQ"))
    rp = {"tool": "pggl-graph reference_files.py", "version": None}
    reference = {
        "sample": REF_SAMPLE,
        "haplotype": 0,
        "path_prefix": REF_PREFIX,
        "contigs": contigs,
        "whole_paths": n_frag == 0 and len(ref_paths) == contigs,
        "fragment_paths": n_frag,
        "fasta": entry("%s.ref.fa" % a.name, rp, note="vg paths -S %s -F on the %s graph" % (REF_SAMPLE, ref_graph)),
        "fai": entry("%s.ref.fa.fai" % a.name, rp),
        "dict": entry("%s.ref.dict" % a.name, rp),
        "pansn_dict": pansn,
        "fasta_source": "graph",
        # extract-reference.sh stops when any contig differs from the source
        "fasta_matches_graph": True,
    }
    check = os.path.join(R, "%s.ref.source-check.tsv" % a.name)
    if os.path.exists(check):
        rows = [l.rstrip("\n").split("\t") for l in open(check)][1:]
        reference["iupac_as_n"] = sum(int(r[4]) for r in rows)
        reference["source_check"] = entry(os.path.basename(check), rp,
            note="per contig: length, source M5, graph M5, IUPAC codes stored as N")
    if a.source_fasta:
        reference["source_fasta"] = {
            "name": os.path.basename(a.source_fasta),
            "size": os.stat(a.source_fasta).st_size,
            "md5": md5sum(a.source_fasta),
        }

    build = json.load(open(a.build_info))
    build.setdefault("method", "minigraph-cactus")
    seqfile = "%s.seqfile.txt" % a.name
    if os.path.exists(os.path.join(R, seqfile)):
        build["seqfile"] = entry(seqfile, {"tool": "hand-written", "version": None})

    index_image = None
    if a.index_image_ref:
        index_image = {"ref": a.index_image_ref, "sha256": a.index_image_sha256}

    root = a.site_root or os.path.abspath(R)
    m = {
        "schema_version": 1,
        "name": a.name,
        "release": a.release,
    }
    if a.description:
        m["description"] = a.description
    m.update({
        "sites": {a.site: {"roots": {"release": root}}},
        "build": build,
        "index_builder": {"vg_version": vg_version, "image": index_image},
        "reference": reference,
        "graphs": graphs,
        "roles": roles,
        "validation": {"status": "not_run", "checks": []},
    })
    with open(a.output, "w") as f:
        json.dump(m, f, indent=2)
        f.write("\n")


if __name__ == "__main__":
    main()
