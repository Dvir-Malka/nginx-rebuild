#!/usr/bin/env python3
"""Compare the baseline scans with the rescan of our image, per scanner.

Usage:  python3 scans/diff.py
Reads:  scans/baseline-{trivy,grype}.json, scans/fixed-{trivy,grype}.json
Writes: scans/DIFF.md
A finding is one (package, CVE) pair, the same key triage.py uses.
"""
import json
from collections import Counter
from pathlib import Path

HERE = Path(__file__).parent
SEVERITIES = ["CRITICAL", "HIGH", "MEDIUM", "LOW", "NEGLIGIBLE", "UNKNOWN"]
# The two CVEs we fixed: one by version bump, one by backport patch.
OUR_FIXES = {"CVE-2025-15467": "version bump of libssl3",
             "CVE-2026-15176": "backport patch to nginx"}


def findings(prefix, scanner):
    """Return {(package, cve): severity} for one JSON report."""
    data = json.loads((HERE / f"{prefix}-{scanner}.json").read_text(encoding="utf-8"))
    found = {}
    if scanner == "trivy":
        for result in data.get("Results", []):
            for v in result.get("Vulnerabilities") or []:
                found[(v["PkgName"], v["VulnerabilityID"])] = v["Severity"].upper()
    else:
        for m in data["matches"]:
            vuln = m["vulnerability"]
            found[(m["artifact"]["name"], vuln["id"])] = vuln["severity"].upper()
    return found


def severity_cells(found):
    counts = Counter(found.values())
    return " | ".join(str(counts.get(s, 0)) for s in SEVERITIES)


out = ["# Rescan diff: nginx:1.25-bookworm (baseline) vs nginx-rebuild:1.25.5 (fixed)", "",
       "Made by `scans/diff.py`. Both scans used the same scanner versions and the same",
       "vulnerability database. A finding is one (package, CVE) pair.", ""]

for scanner in ("trivy", "grype"):
    before, after = findings("baseline", scanner), findings("fixed", scanner)
    removed = sorted(before.keys() - after.keys())
    added = sorted(after.keys() - before.keys())
    unchanged = before.keys() & after.keys()

    out += [f"## {scanner.capitalize()}", "",
            "| | total | " + " | ".join(s.lower() for s in SEVERITIES) + " |",
            "|---|---:|" + "---:|" * len(SEVERITIES),
            f"| baseline | {len(before)} | {severity_cells(before)} |",
            f"| fixed | {len(after)} | {severity_cells(after)} |", "",
            f"Removed {len(removed)}, added {len(added)}, unchanged {len(unchanged)}.", "",
            "Our two fixes:", ""]
    for cve, how in OUR_FIXES.items():
        b = sorted(p for p, c in before if c == cve) or ["not listed"]
        a = sorted(p for p, c in after if c == cve) or ["not listed"]
        out.append(f"- {cve} ({how}): baseline {', '.join(b)}; fixed {', '.join(a)}")

    # Added findings are few and each needs an explanation, so list them all.
    out += ["", f"### Added ({len(added)})", ""]
    out += [f"- {p} {c} ({after[(p, c)].lower()})" for p, c in added] or ["- none"]
    # Removed findings are hundreds; a count per package is readable.
    out += ["", f"### Removed ({len(removed)}), count per package", ""]
    out += [f"- {p}: {n}" for p, n in sorted(Counter(p for p, _ in removed).items())] or ["- none"]
    out.append("")

(HERE / "DIFF.md").write_text("\n".join(out), encoding="utf-8", newline="\n")
print(f"wrote {HERE / 'DIFF.md'}")
