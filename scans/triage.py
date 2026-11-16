#!/usr/bin/env python3
"""Merge the Trivy and Grype JSON reports into one CSV, one row per (package, CVE).

Usage:  python3 scans/triage.py baseline
Reads:  scans/<prefix>-trivy.json, scans/<prefix>-grype.json
Writes: scans/<prefix>-cves.csv, and prints a summary per package.
"""
import csv
import json
import sys
from pathlib import Path

HERE = Path(__file__).parent
PREFIX = sys.argv[1] if len(sys.argv) > 1 else "baseline"
# Worst first, so "the worst severity of a package" is the lowest index.
SEVERITIES = ["CRITICAL", "HIGH", "MEDIUM", "LOW", "NEGLIGIBLE", "UNKNOWN"]
# Packages the nginx binary loads at run time: the Depends line of
# `dpkg -s nginx` in the upstream image, confirmed with `ldd /usr/sbin/nginx`.
LOADED_BY_NGINX = {"libc6", "libcrypt1", "libpcre2-8-0", "libssl3", "zlib1g"}
# Package names in a plain debian:bookworm-slim, one per line. Made with:
#   docker run --rm debian:bookworm-slim dpkg-query -W -f '${Package}\n'
BASE_OS = set((HERE / "bookworm-slim-packages.txt").read_text().split())


def group_of(package):
    """Where a finding lives, which decides how it can be fixed."""
    if package == "nginx":
        return "nginx"
    if package in LOADED_BY_NGINX:
        return "loaded by nginx"
    if package in BASE_OS:
        return "base OS"
    return "added by nginx image"


def method_of(row):
    """One rule per group; nginx rows are handled one by one in TRIAGE.md."""
    if row["group"] == "nginx":
        return "backport or accept (see TRIAGE.md)"
    if row["fixed"]:
        return "bump"  # Debian 12 ships a fixed version
    if row["group"] == "added by nginx image":
        return "accept or remove (no fix in Debian 12)"
    return "accept (no fix in Debian 12)"

rows = {}  # (package, cve) -> row


def add(package, cve, scanner, installed, fixed, severity, source=""):
    """Record one finding. Both scanners land in the same row when they agree."""
    row = rows.setdefault((package, cve), {
        "package": package, "cve": cve, "installed": installed, "fixed": "",
        "trivy": "", "grype": "", "grype_source": "",
    })
    row[scanner] = severity.upper()
    row["fixed"] = row["fixed"] or fixed
    row["grype_source"] = row["grype_source"] or source


def load(scanner):
    return json.loads((HERE / f"{PREFIX}-{scanner}.json").read_text(encoding="utf-8"))


for result in load("trivy").get("Results", []):
    for v in result.get("Vulnerabilities") or []:
        add(v["PkgName"], v["VulnerabilityID"], "trivy",
            v["InstalledVersion"], v.get("FixedVersion", ""), v["Severity"])

for match in load("grype")["matches"]:
    vuln, pkg = match["vulnerability"], match["artifact"]
    fixed = ", ".join(vuln.get("fix", {}).get("versions") or [])
    # "namespace" says which database the match came from (Debian's or NVD).
    add(pkg["name"], vuln["id"], "grype",
        pkg["version"], fixed, vuln["severity"], vuln.get("namespace", ""))

for row in rows.values():
    row["group"] = group_of(row["package"])
    row["method"] = method_of(row)

ordered = sorted(rows.values(), key=lambda r: (r["package"], r["cve"]))
with open(HERE / f"{PREFIX}-cves.csv", "w", newline="", encoding="utf-8") as f:
    writer = csv.DictWriter(f, fieldnames=list(ordered[0]))
    writer.writeheader()
    writer.writerows(ordered)

# Summary per package: this is the view we triage from.
print(f"{'package':24} {'group':21} {'cves':>4} {'bump':>4} {'worst':10} {'trivy':>5} {'grype':>5}")
totals = {}  # group -> [cves, bump]
for package in sorted({r["package"] for r in ordered}):
    mine = [r for r in ordered if r["package"] == package]
    worst = min((s for r in mine for s in (r["trivy"], r["grype"]) if s),
                key=SEVERITIES.index)
    bump = sum(1 for r in mine if r["method"] == "bump")
    group = mine[0]["group"]
    print(f"{package:24} {group:21} {len(mine):4} {bump:4} {worst:10} "
          f"{sum(1 for r in mine if r['trivy']):5} {sum(1 for r in mine if r['grype']):5}")
    totals.setdefault(group, [0, 0])
    totals[group][0] += len(mine)
    totals[group][1] += bump

print()
for group, (cves, bump) in sorted(totals.items()):
    print(f"{group:21} {cves:4} findings, {bump:4} fixable by bump")
print(f"\n{len(ordered)} rows written to scans/{PREFIX}-cves.csv")
