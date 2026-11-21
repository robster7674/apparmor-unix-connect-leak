#!/usr/bin/env python3
"""Turn the guest test output of one kernel (base + fix) into a markdown table, and check it.

Usage: summarize.py <name> <results dir> <label-base> <label-fix>
Exit 1 if a test line is missing, or the fix run still leaks (T1 not freed, T3 not 2 frees, T4 problems).
The unpatched run is only reported: once upstream fixes the bug it will stop leaking, and that is a result, not an error.
"""
import glob
import re
import sys


def results(path):
    r = {}
    for line in open(path, errors="replace"):
        m = re.match(r"RESULT (T\d)\s*(.*)", line)
        if m:
            r.setdefault(m.group(1), []).append(m.group(2).strip())
    return r


def main():
    name, d, lb, lf = sys.argv[1:5]
    got = {}
    for lab in (lb, lf):
        files = glob.glob(f"{d}/test-*-{lab}.txt")
        got[lab] = results(files[0]) if files else {}
    print(f"### {name}\n\n| test | unpatched | fix |\n|---|---|---|")
    for t in ("T1", "T2", "T3", "T4"):
        print(f"| {t} | " + " <br> ".join(got[lb].get(t, ["missing"])) + " | " + " <br> ".join(got[lf].get(t, ["missing"])) + " |")
    bad = [t for t in ("T1", "T2", "T3", "T4") if t not in got[lb] or t not in got[lf]]
    fix = got[lf]
    if any("NOT_FREED" in x for x in fix.get("T1", [])): bad.append("fix T1 leaks")
    if any(not x.startswith("frees=2 ") for x in fix.get("T3", [])): bad.append("fix T3 not 2 frees")
    if any(not x.startswith("problems=0 ") for x in fix.get("T4", [])): bad.append("fix T4 kernel log")
    base_leaks = any("NOT_FREED" in x for x in got[lb].get("T1", []))
    print(f"\nUnpatched leaks: **{'yes' if base_leaks else 'no'}**. Checks: {', '.join(bad) if bad else 'ok'}.")
    sys.exit(1 if bad else 0)


main()
