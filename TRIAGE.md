# CVE triage: `nginx:1.25-bookworm`

Baseline image: `nginx@sha256:a484819eb60211f5299034ac80f6a681b06f89e65866ce91f356ed7c72af059c`
Scanned 16 Nov 2026 with Trivy 0.76.2 and Grype 0.121.3.

## Inputs

| File | What it is |
|---|---|
| `scans/baseline-trivy.txt`, `.json` | Trivy report: 933 findings |
| `scans/baseline-grype.txt`, `.json` | Grype report: 881 findings |
| `scans/triage.py` | Merges both JSON reports, adds group and method |
| `scans/baseline-cves.csv` | Output: 941 rows, one per package + CVE |
| `scans/baseline-summary.txt` | Output: one line per package (83 packages) |

Rebuild the table with `python3 scans/triage.py baseline`.

## How every CVE was triaged

There are 941 findings in 83 packages. I did not read them one by one. The fix
method depends on where a finding lives, so I grouped the packages and applied
one rule per group. The CSV has the answer for every row:

| Brief asks | CSV column |
|---|---|
| The binary or library it lives in | `package`, `group` |
| Whether a fix exists, and in which version | `fixed` (the Debian 12 package version with the fix; empty = no fix in Debian 12) |
| Bump, backport or remove | `method` |

The four groups:

| Group | How it is decided | Packages | Findings | Fixable by bump | Method for the rest |
|---|---|---|---|---|---|
| nginx | the `nginx` package | 1 | 8 | 0 | backport or accept, see below |
| loaded by nginx | `Depends` of the nginx package, confirmed with `ldd /usr/sbin/nginx` | 4 | 100 | 64 | accept |
| added by nginx image | not present in a plain `debian:bookworm-slim` | 32 | 548 | 225 | accept or remove |
| base OS | present in a plain `debian:bookworm-slim` | 46 | 285 | 88 | accept |

"Fixable by bump" means Debian 12 already ships a package version with the fix.
A finding is counted once per binary package, so one OpenSSL CVE appears under
both `libssl3` and `openssl`.

### Libraries the nginx binary loads

| Package | Installed | Findings | Fixable by bump | Worst severity |
|---|---|---|---|---|
| `libssl3` (OpenSSL) | 3.0.11-1~deb12u2 | 54 | 48 | Critical |
| `libc6` | 2.36-9+deb12u7 | 35 | 9 | Critical |
| `libpcre2-8-0` | 10.42-1 | 7 | 7 | High |
| `zlib1g` | 1:1.2.13.dfsg-1 | 4 | 0 | Critical |
| `libcrypt1` | 1:4.4.33-2 | 0 | 0 | none |

### Largest packages outside nginx

| Package | Group | Findings | Fixable by bump |
|---|---|---|---|
| `libheif1` | added by nginx image | 73 | 3 |
| `curl`, `libcurl4` | added by nginx image | 52 each | 14 each |
| `openssl` (command-line tool) | added by nginx image | 54 | 48 |
| `libexpat1` | added by nginx image | 42 | 33 |
| `libtiff6` | added by nginx image | 33 | 9 |
| `libxml2` | added by nginx image | 30 | 21 |
| Kerberos libraries (4 packages) | added by nginx image | 30 each | 7 each |
| `libc-bin` | base OS | 35 | 9 |
| `libgnutls30` | base OS | 27 | 21 |
| `perl-base` | base OS | 21 | 16 |

All 83 packages are in `scans/baseline-summary.txt`.

## nginx itself

The nginx in this image is nginx.org's package (`1.25.5-1~bookworm`), not
Debian's (Debian 12 ships 1.22.1). That breaks both scanners:

- **Trivy reports nothing for nginx.**
- **Grype reports 8 CVEs**, all from Debian's data, matched on the package name.
  Debian's tracker lists no fixed version of Debian's nginx in Debian 12 for
  these 8, so Grype flags any package called `nginx`, whatever its version.
- **nginx.org lists 29 advisories whose range covers 1.25.5.** Grype shows 5 of
  them. The other 24 are invisible to both scanners.

Source: <https://nginx.org/en/security_advisories.html>, read 16 Nov 2026.

The 8 rows Grype reports, checked against nginx.org and Debian's tracker:

| CVE | Grype | What it is | Affects 1.25.5? | Upstream fix | Method |
|---|---|---|---|---|---|
| [CVE-2026-15176](https://security-tracker.debian.org/tracker/CVE-2026-15176) | Critical | Buffer overflow with `alias` + `rewrite` | Yes (0.1.29–1.31.6) | 1.31.7, 1.30.6 | **backport** |
| [CVE-2026-97205](https://security-tracker.debian.org/tracker/CVE-2026-97205) | Critical | Use-after-free with async file I/O and SSI | Yes (0.8.11–1.31.6) | 1.31.7, 1.30.6 | accept; backport candidate |
| [CVE-2026-97629](https://security-tracker.debian.org/tracker/CVE-2026-97629) | High | Forged TLS sessions via session tickets | Yes (1.23.2–1.31.6) | 1.31.7, 1.30.6 | accept; backport candidate |
| [CVE-2026-95101](https://security-tracker.debian.org/tracker/CVE-2026-95101) | Medium | HTTP/3 request body injection | Yes (1.25.0–1.31.6) | 1.31.7, 1.30.6 | accept; backport candidate |
| [CVE-2026-93479](https://security-tracker.debian.org/tracker/CVE-2026-93479) | Critical | Buffer overflow in script evaluation | No: nginx.org lists 1.30.0–1.30.5 and 1.31.2–1.31.6 | 1.31.7, 1.30.6 | none: false positive for this version |
| [CVE-2023-44487](https://security-tracker.debian.org/tracker/CVE-2023-44487) | High | HTTP/2 "rapid reset" denial of service | Not confirmed; not among nginx.org's advisories covering 1.25.5 | not checked | not triaged further |
| [CVE-2009-4487](https://security-tracker.debian.org/tracker/CVE-2009-4487) | Negligible | Escape sequences written to logs | Yes ("all") | none; Debian: "unimportant" | accept |
| [CVE-2013-0337](https://security-tracker.debian.org/tracker/CVE-2013-0337) | Negligible | World-readable log files | Configuration matter | none; Debian: "unimportant" | accept |

nginx.org rates the four 2026 advisories that affect 1.25.5 "medium". Grype
rates two of them Critical. Severity depends on who you ask.

## The CVEs I chose

### Backport: CVE-2026-15176 (nginx)

A heap buffer overflow in a worker process when a location uses `alias` and a
`rewrite` changes the URI before it is mapped to a file path.

- **Why backport:** no fixed 1.25.x exists. The fix is only in 1.31.7 and 1.30.6.
- **It affects our version:** nginx.org range 0.1.29–1.31.6.
- **The fix is small:** one line in `src/http/ngx_http_core_module.c`, upstream
  commit [`f8a2342`](https://github.com/nginx/nginx/commit/f8a23425bd6840c4c36b4264edf576ba3646156f)
  (mainline) / [`ce1da78`](https://github.com/nginx/nginx/commit/ce1da78900b07e72f37a25f55e6606220ac45902) (stable).
- **It is testable:** the commit message contains a config and request that
  trigger the overflow.
- **It is in the core HTTP module**, which is always compiled in.
- **A scanner reports it**, so a VEX statement has something to suppress.
- **Debian backported the same change** to nginx 1.26.3:
  <https://sources.debian.org/patches/nginx/1.26.3-3+deb13u10/CVE-2026-15176.patch/>

### Version bump: CVE-2025-15467 (OpenSSL, `libssl3`)

A stack buffer overflow in OpenSSL when parsing an encrypted CMS message; it
happens before authentication.
Tracker: <https://security-tracker.debian.org/tracker/CVE-2025-15467>

- **Why bump:** Debian 12 ships the fix. Installed `3.0.11-1~deb12u2`, fixed in
  `3.0.18-1~deb12u2` (DSA-6113-1); upstream fix is in OpenSSL 3.0.19.
- **nginx loads this library** for all TLS (`ldd`), and it links dynamically, so
  a newer package fixes it without recompiling nginx.
- **Both scanners report it** (Trivy High, Grype Critical), so the rescan can
  show it gone.
- **The same bump fixes 47 other `libssl3` findings.**
- **Not verified:** whether nginx ever calls OpenSSL's CMS code. If it does not,
  this CVE was not reachable through nginx in the first place.

### Why not others

| Candidate | Why not |
|---|---|
| CVE-2026-97205, -97629, -95101 (nginx) | Each would need more setup to prove the fix: an async file I/O + SSI setup, TLS certificates and session resumption, or an HTTP/3 client (Python's standard library has none). CVE-2026-15176 needed only plain HTTP and comes with a reproducer. I did not read their fixes. |
| CVE-2026-42945 and 23 other nginx.org advisories | They affect 1.25.5 but no scanner reports them. Left as residual risk. I did not read their fixes. |
| CVE-2024-7347 (nginx mp4 module) | Fallback backport: nginx.org publishes an official patch file. No scanner reports it. |
| `zlib1g` | 4 findings, none with a fix in Debian 12. Nothing to bump to. |
| `libc6`, `libpcre2-8-0` | Valid bump targets (9 and 7 fixable). OpenSSL has more findings and higher severity. |
| CVE-2026-31789 (OpenSSL) | The only `libssl3` finding both scanners rate Critical, but OpenSSL rates it Low: 32-bit platforms only. |
| Packages nginx does not load | Easy to bump or remove, but that shows nothing about nginx. |

## Limits of this triage

- **The method column is rule-based.** I did not check, per CVE, whether the
  vulnerable code is reachable from nginx.
- **I read the fix for one nginx CVE only**, the one I chose. I stopped when it
  met every criterion and did not compare patch sizes across candidates.
- **"No fix in Debian 12" is as of the scan date** (16 Nov 2026).
- **CVE-2023-44487 is unresolved** for this version.
