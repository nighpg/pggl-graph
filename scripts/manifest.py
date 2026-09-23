#!/usr/bin/env python3
"""Write, check and use graph.manifest.json (schema/graph.manifest.schema.json).

  manifest.py entry  <root-name> <root-dir> <relpath> --tool T --version V
                     [--format-version N] [--note TEXT] [--md5 HEX]
      Print one file entry (size and md5 are taken from the file; --md5 skips
      the hashing when the sum is already known).

  manifest.py check  <manifest> [--site S] [--sizes] [--md5] [--contract]
      Validate the manifest. Exit 1 on a malformed manifest or a file that does
      not match it. With --contract, also check what pggl-workflow relies on and
      exit 3 when the release breaks it (the same code vg-call-sv.sh uses for a
      fragmented reference).

  manifest.py job    <manifest> --site S
      Print the pggl-workflow inputs for this release as a CWL job fragment.

  manifest.py resolve <manifest> --site S
      Print shell assignments (for eval) of everything validate-graph.sh needs.

  manifest.py set-validation <manifest> <validation.json>
      Replace the manifest's validation block with a validate-graph.sh result.

Only the standard library is required. The schema is enforced with jsonschema
when it is installed; the checks below the schema run either way.
"""
import argparse
import hashlib
import json
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
SCHEMA = os.path.join(HERE, "..", "schema", "graph.manifest.schema.json")

# Which files each pggl-workflow use takes from its graph
ROLE_FILES = {
    "giraffe": ["gbz", "dist", "min", "zipcodes"],
    "haplotype_sampling": ["gbz", "ri", "hapl"],
    "call_sv": ["snarls"],
    "pangenome_aware_dv": ["gbz"],
}
INDEX_KEYS = ["gbz", "dist", "min", "zipcodes", "snarls", "ri", "hapl"]


def md5sum(path, bufsize=1 << 24):
    h = hashlib.md5()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(bufsize), b""):
            h.update(chunk)
    return h.hexdigest()


def file_entries(m):
    """Yield (label, entry) for every file entry in the manifest."""
    b = m.get("build", {})
    if b.get("seqfile"):
        yield "build.seqfile", b["seqfile"]
    for k in ["fasta", "fai", "dict", "pansn_dict"]:
        if m.get("reference", {}).get(k):
            yield "reference." + k, m["reference"][k]
    for g, files in m.get("graphs", {}).items():
        for k in INDEX_KEYS:
            if files.get(k):
                yield "graphs.%s.%s" % (g, k), files[k]
    for k, e in m.get("other_files", {}).items():
        yield "other_files." + k, e
    if m.get("validation", {}).get("report"):
        yield "validation.report", m["validation"]["report"]


def resolve(m, site, entry):
    """Absolute path of a file entry. A relative root is taken relative to the
    manifest's own directory, which keeps a checked-in release relocatable."""
    root = m["sites"][site]["roots"][entry["root"]]
    return os.path.normpath(os.path.join(m.get("_dir", "."), root, entry["path"]))


def load(path):
    m = json.load(open(path))
    m["_dir"] = os.path.dirname(os.path.abspath(path))
    return m


def cmd_entry(a):
    full = os.path.join(a.root_dir, a.relpath)
    e = {
        "root": a.root_name,
        "path": a.relpath,
        "size": os.stat(full).st_size,
        "md5": a.md5 or md5sum(full),
        "producer": {"tool": a.tool, "version": a.version},
    }
    if a.format_version is not None:
        e["format_version"] = a.format_version
    if a.note:
        e["note"] = a.note
    json.dump(e, sys.stdout, indent=2)
    print()


def structural_errors(m):
    m = {k: v for k, v in m.items() if k != "_dir"}
    errs = []
    try:
        import jsonschema
        schema = json.load(open(SCHEMA))
        v = jsonschema.Draft7Validator(schema)
        for e in sorted(v.iter_errors(m), key=lambda e: list(e.path)):
            where = "/".join(str(p) for p in e.path) or "(top)"
            errs.append("schema: %s: %s" % (where, e.message))
    except ImportError:
        print("note: jsonschema not installed; schema not enforced", file=sys.stderr)
    if errs:
        return errs  # the checks below assume a well-formed manifest

    for site, s in m["sites"].items():
        for label, e in file_entries(m):
            if e["root"] not in s["roots"]:
                errs.append("%s: root '%s' not defined for site '%s'" % (label, e["root"], site))
    for role, g in m["roles"].items():
        if g not in m["graphs"]:
            errs.append("roles.%s: graph '%s' is not in graphs" % (role, g))
            continue
        for k in ROLE_FILES[role]:
            if k not in m["graphs"][g]:
                errs.append("roles.%s: graphs.%s has no %s" % (role, g, k))
    return errs


def file_errors(m, site, sizes, md5):
    errs = []
    for label, e in file_entries(m):
        p = resolve(m, site, e)
        if not os.path.exists(p):
            errs.append("%s: %s missing" % (label, p))
            continue
        if sizes or md5:
            st = os.stat(p).st_size
            if st != e["size"]:
                errs.append("%s: size %d, manifest says %d" % (label, st, e["size"]))
                continue
        if md5:
            h = md5sum(p)
            if h != e["md5"]:
                errs.append("%s: md5 %s, manifest says %s" % (label, h, e["md5"]))
    return errs


def contract_violations(m):
    """What pggl-workflow relies on, judged from the manifest alone."""
    out = []
    ref = m["reference"]
    order = m["build"]["reference_order"]
    if order[0] != ref["sample"]:
        out.append("--reference starts with %s, not %s: %s is clipped into subrange paths"
                   % (order[0], ref["sample"], ref["sample"]))
    if len(order) > 1:
        out.append("more than one --reference (%s): reference_samples is not %s alone"
                   % (" ".join(order), ref["sample"]))
    if not ref["whole_paths"] or ref.get("fragment_paths"):
        out.append("%s is not whole paths (%s fragment paths)"
                   % (ref["sample"], ref.get("fragment_paths")))
    if ref.get("fasta_source") != "graph":
        out.append("reference.fasta is not extracted from the graph")
    if ref.get("fasta_matches_graph") is not True:
        out.append("reference.fasta is not confirmed md5-identical to the graph")
    vg = m["index_builder"]["vg_version"]
    for g, files in m["graphs"].items():
        for k in INDEX_KEYS:
            e = files.get(k)
            if not e:
                continue
            p = e["producer"]
            if p["tool"] != "vg" or p["version"] != vg:
                out.append("graphs.%s.%s produced by %s %s, not vg %s"
                           % (g, k, p["tool"], p["version"], vg))
        if ref["sample"] not in files.get("reference_samples", [ref["sample"]]):
            out.append("graphs.%s: %s not in reference_samples" % (g, ref["sample"]))
    if m["validation"]["status"] != "pass":
        out.append("validation status is %s" % m["validation"]["status"])
    return out


def cmd_check(a):
    m = load(a.manifest)
    errs = structural_errors(m)
    if not errs and a.site:
        if a.site not in m["sites"]:
            errs.append("site '%s' not in sites (%s)" % (a.site, ", ".join(m["sites"])))
        else:
            errs += file_errors(m, a.site, a.sizes, a.md5)
    for e in errs:
        print("ERROR  " + e)
    if errs:
        return 1
    print("OK     manifest %s %s is well formed%s"
          % (m["name"], m["release"], " and matches site " + a.site if a.site else ""))
    if a.contract:
        v = contract_violations(m)
        for x in v:
            print("BREAKS " + x)
        if v:
            return 3
        print("OK     release meets the pggl-workflow contract")
    return 0


def cmd_job(a):
    m = load(a.manifest)
    if a.site not in m["sites"]:
        sys.exit("site '%s' not in sites (%s)" % (a.site, ", ".join(m["sites"])))
    roles = m["roles"]

    def f(entry):
        return {"class": "File", "path": resolve(m, a.site, entry)}

    job = {}
    if "giraffe" in roles:
        g = m["graphs"][roles["giraffe"]]
        for k in ROLE_FILES["giraffe"]:
            job[k] = f(g[k])
    if "call_sv" in roles:
        job["snarls"] = f(m["graphs"][roles["call_sv"]]["snarls"])
    ref = m["reference"]
    if ref.get("fasta"):
        job["ref"] = f(ref["fasta"])
    job["ref_paths"] = f(ref["pansn_dict"])
    job["ref_path_prefix"] = ref["path_prefix"]
    print("# pggl-workflow inputs from %s %s (site %s)" % (m["name"], m["release"], a.site))
    if "haplotype_sampling" in roles:
        g = m["graphs"][roles["haplotype_sampling"]]
        print("# haplotype-sample.cwl: gbz=%s hapl=%s"
              % (resolve(m, a.site, g["gbz"]), resolve(m, a.site, g["hapl"])))
    json.dump(job, sys.stdout, indent=2)
    print()


def cmd_resolve(a):
    import shlex
    m = load(a.manifest)
    if a.site not in m["sites"]:
        sys.exit("site '%s' not in sites (%s)" % (a.site, ", ".join(m["sites"])))
    ref = m["reference"]
    out = [
        ("NAME", m["name"]),
        ("RELEASE", m["release"]),
        ("REF_SAMPLE", ref["sample"]),
        ("REF_PREFIX", ref["path_prefix"]),
        ("REF_CONTIGS", str(ref["contigs"])),
        ("PANSN_DICT", resolve(m, a.site, ref["pansn_dict"])),
        ("FAI", resolve(m, a.site, ref["fai"]) if ref.get("fai") else ""),
        ("GRAPHS", " ".join(sorted(m["graphs"]))),
        ("GIRAFFE_GRAPH", m["roles"].get("giraffe", "")),
        ("INDEX_VG", m["index_builder"]["vg_version"]),
        ("ROOT_DIRS", ",".join(sorted(set(os.path.normpath(os.path.join(m["_dir"], r))
                                          for r in m["sites"][a.site]["roots"].values())))),
    ]
    for g, files in sorted(m["graphs"].items()):
        for k in INDEX_KEYS:
            if files.get(k):
                out.append(("G_%s_%s" % (g, k), resolve(m, a.site, files[k])))
    for k, v in out:
        print("%s=%s" % (k, shlex.quote(v)))


def cmd_set_validation(a):
    m = load(a.manifest)
    v = json.load(open(a.validation))
    m["validation"] = v
    m.pop("_dir")
    with open(a.manifest, "w") as f:
        json.dump(m, f, indent=2)
        f.write("\n")
    errs = structural_errors(m)
    for e in errs:
        print("ERROR  " + e)
    return 1 if errs else 0


def main():
    p = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    sub = p.add_subparsers(dest="cmd")
    sub.required = True

    e = sub.add_parser("entry")
    e.add_argument("root_name")
    e.add_argument("root_dir")
    e.add_argument("relpath")
    e.add_argument("--tool", required=True)
    e.add_argument("--version", required=True, help="'null' when unknown")
    e.add_argument("--format-version", type=int)
    e.add_argument("--note")
    e.add_argument("--md5")
    e.set_defaults(func=cmd_entry)

    c = sub.add_parser("check")
    c.add_argument("manifest")
    c.add_argument("--site")
    c.add_argument("--sizes", action="store_true")
    c.add_argument("--md5", action="store_true")
    c.add_argument("--contract", action="store_true")
    c.set_defaults(func=cmd_check)

    j = sub.add_parser("job")
    j.add_argument("manifest")
    j.add_argument("--site", required=True)
    j.set_defaults(func=cmd_job)

    r = sub.add_parser("resolve")
    r.add_argument("manifest")
    r.add_argument("--site", required=True)
    r.set_defaults(func=cmd_resolve)

    s = sub.add_parser("set-validation")
    s.add_argument("manifest")
    s.add_argument("validation")
    s.set_defaults(func=cmd_set_validation)

    a = p.parse_args()
    if a.cmd == "entry" and a.version == "null":
        a.version = None
    sys.exit(a.func(a) or 0)


if __name__ == "__main__":
    main()
