#!/usr/bin/env python3
"""Print the kernels to test as a JSON list for a GitHub Actions matrix.

Newest longterm, newest stable and the head of mainline, each resolved to a full commit SHA, so a run says exactly
what it built. Older longterm branches are left out on purpose: the bug came in with v6.17 and they have no
apparmor_unix_stream_connect() at all.

Usage: resolve-kernels.py [longterm|stable|mainline ...]   (no argument: all three)
"""
import json
import subprocess
import sys
import urllib.request

TORVALDS = "https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git"
STABLE = "https://git.kernel.org/pub/scm/linux/kernel/git/stable/linux.git"


def ls_remote(repo, ref):
    out = subprocess.run(["git", "ls-remote", repo, ref, ref + "^{}"], check=True, capture_output=True, text=True).stdout
    shas = {line.split("\t")[1]: line.split("\t")[0] for line in out.splitlines()}
    sha = shas.get(ref + "^{}") or shas.get(ref)  # peeled tag if annotated
    if not sha:
        sys.exit(f"{ref} not found in {repo}")
    return sha


def newest(releases, moniker):
    cands = [r for r in releases if r["moniker"] == moniker and not r.get("iseol")]
    return max(cands, key=lambda r: [int(x) for x in r["version"].split("-")[0].split(".")]) if cands else None


def main():
    want = sys.argv[1:] or ["longterm", "stable", "mainline"]
    with urllib.request.urlopen("https://www.kernel.org/releases.json", timeout=30) as f:
        releases = json.load(f)["releases"]
    out = []
    for kind in want:
        if kind == "mainline":
            ref = "refs/heads/master"
            out.append({"kind": kind, "name": "mainline-head", "repo": TORVALDS, "ref": ref, "sha": ls_remote(TORVALDS, ref)})
            continue
        r = newest(releases, kind)
        if not r:
            sys.exit(f"no {kind} release in releases.json")
        ref = f"refs/tags/v{r['version']}"
        out.append({"kind": kind, "name": f"{kind}-{r['version']}", "repo": STABLE, "ref": ref, "sha": ls_remote(STABLE, ref)})
    print(json.dumps(out))


if __name__ == "__main__":
    main()
