# nginx 1.25.5, rebuilt from source

This repo rebuilds the `nginx:1.25-bookworm` container image from upstream source.
It compiles nginx 1.25.5 (plus the xslt, geoip, image-filter and njs modules) into
`.deb` packages inside a clean `debian:bookworm-slim`, fixes two CVEs (one by
backport patch, one by version bump), and installs the packages into an image that
is meant to be a drop-in replacement for upstream. A Python test boots both images
and checks that they answer identically.

## Build

Prerequisites: Docker, `make`, Python 3 (standard library only), and internet access
(the build downloads the nginx tarball, njs from GitHub, and Debian packages).
Trivy and Grype need no install: `make scan` runs them as containers
(`aquasec/trivy:0.76.2`, `anchore/grype:v0.121.3`) and Docker downloads those
images on first use.
Tested on Linux x86_64 (Ubuntu 24.04 under WSL2, Docker 29.9.3).

| Command | What it does |
|---|---|
| `make all` (= `make image`) | builds the `.deb`s from source (`make deb`), then the image `nginx-rebuild:1.25.5` from `Containerfile` |
| `make deb` | `build/Dockerfile` + `build/build.sh`: download and verify the sources, apply `build/patches/*.patch`, compile, package; the `.deb`s land in `dist/` |
| `make test` | builds the image, then compares it with `nginx:1.25-bookworm` (`test/compat_test.py`, see `test/README.md`); exits non-zero on mismatch |
| `make cve-test` | builds the image, then runs `test/cve-2026-15176.sh`: passes if our image rejects the CVE's reproducer and upstream does not |
| `make scan` | builds the image, scans it with Trivy and Grype, writes `scans/fixed-*` and `scans/DIFF.md` |
| `make vex-scan` | the same scans with the OpenVEX file in `vex/` applied, writes `scans/vex-*` |
| `make clean` | deletes `dist/` |

A first build takes about 3 minutes (measured with `docker build --no-cache` on a
16-core machine; longer on fewer cores); repeat runs reuse Docker's cache and take seconds.

Notes:
- Scanners compare the image against a vulnerability database that is updated
  several times a day. `make scan` downloads the current one, so its counts will
  differ from the committed reports in `scans/`, which used the databases of
  16 Nov 2026. To compare two of your own runs on equal terms, keep the database
  fixed after a first normal run has cached it:
  `make scan TRIVY_DB_FLAGS="--skip-db-update --skip-java-db-update" GRYPE_DB_AUTO_UPDATE=false`.
- On Linux the scan reports are written by the scanner containers as root, so files
  in `scans/` end up owned by root.

## Image size

| Image | Files in the image (`du -sxb /`) | `docker image inspect` `.Size` |
|---|---|---|
| `nginx:1.25-bookworm` (original) | 188.6 MB | 273.1 MB |
| `nginx-rebuild:1.25.5` (new) | 187.8 MB | 270.9 MB |

MB = 10^6 bytes. Both images were measured with the same two commands:

    docker run --rm --entrypoint du IMAGE -sxb /
    docker image inspect --format '{{.Size}}' IMAGE

The columns measure different things. `du` adds up the files a container sees.
Docker's `.Size` is larger here (Docker Desktop 29.9.3, containerd image store), and
what it counts depends on the Docker setup, so compare within one column only.

The new image is 0.8 MB (0.4%) smaller. Both use the same 85.3 MB Debian base layer;
the difference is in the nginx install layer. Our nginx package leaves out files that
upstream's package ships but the container never uses (init script, systemd unit,
logrotate config, man page, docs), and its dependencies come from Debian 12.15
instead of 12.5. The difference was not broken down further.

## CVEs fixed

| CVE | Severity | Component | Fix | Evidence |
|---|---|---|---|---|
| [CVE-2026-15176](https://security-tracker.debian.org/tracker/CVE-2026-15176) | Grype Critical, Trivy High, nginx.org medium | nginx 1.25.5: heap buffer overflow with `alias` + `rewrite` | **backport patch** | [`build/patches/CVE-2026-15176.patch`](build/patches/CVE-2026-15176.patch) = upstream commit [`f8a2342`](https://github.com/nginx/nginx/commit/f8a23425bd6840c4c36b4264edf576ba3646156f) unmodified; reproducer [`test/cve-2026-15176.sh`](test/cve-2026-15176.sh) |
| [CVE-2025-15467](https://security-tracker.debian.org/tracker/CVE-2025-15467) | Grype Critical, Trivy High | OpenSSL `libssl3`: stack buffer overflow parsing CMS messages | **version bump** `3.0.11-1~deb12u2` → `3.0.22-1~deb12u2` | before: [`scans/baseline-grype.txt`](scans/baseline-grype.txt) line 7; after: not in [`scans/fixed-grype.txt`](scans/fixed-grype.txt) or `fixed-trivy.txt`, see [`scans/DIFF.md`](scans/DIFF.md) |

**CVE-2026-15176 (backport).** No fixed 1.25.x exists; the fix is only in 1.31.7 and
1.30.6. The upstream commit is a one-line change in `src/http/ngx_http_core_module.c`
and applies to 1.25.5 without changes (offset -103 lines). `build/build.sh` applies
every file in `build/patches/` with `patch --fuzz=0`, so the build fails if a hunk does
not match exactly. The package revision went from `+echo1` to `+echo2`.
`test/cve-2026-15176.sh` sends the request from the commit message to both images:
upstream answers without any alert (the overflow is undefined behaviour: in our runs
one upstream build dropped the connection, another returned 200 with overwritten
memory in its debug log), ours logs
`"alias" cannot be used in location "/foo/" where URI was rewritten`.
The scanners still list this CVE on our image, because they match on the version
string `1.25.5`; see "Rescan and VEX" below.

**CVE-2025-15467 (version bump).** Debian 12 fixed it in `3.0.18-1~deb12u2`
(DSA-6113-1). nginx links OpenSSL dynamically, so no recompile is needed: our `nginx`
and `nginx-module-njs` packages declare `Depends: libssl3 (>= 3.0.18-1~deb12u2)`
([`build/build.sh`](build/build.sh)), and apt installs the current bookworm version,
`3.0.22-1~deb12u2`. The same bump removes 47 other `libssl3` findings.

## How I chose them

Full triage: [`TRIAGE.md`](TRIAGE.md). Summary:

- The baseline has 941 findings in 83 packages (Trivy 933, Grype 881, merged by
  [`scans/triage.py`](scans/triage.py) into [`scans/baseline-cves.csv`](scans/baseline-cves.csv)).
  I did not read them one by one: I grouped the packages (nginx itself, libraries
  nginx loads, packages the nginx image adds, base OS) and applied one rule per group.
  The CSV records, for every finding, the package, whether Debian 12 has a fix, and
  the method (bump, backport, remove, accept).
- **Backport, from nginx itself.** I picked CVE-2026-15176 because it affects 1.25.5, the fix is
  one line in the always-compiled core HTTP module, the commit message includes a
  reproducer, a scanner reports it (so the VEX step has something to act on), and
  Debian backported the same change to its own nginx.
- **Bump, from a library nginx loads.** OpenSSL (`libssl3`) had the most findings
  among the libraries nginx links to (54, 48 of them fixed in Debian 12) and the
  highest severity. CVE-2025-15467 is reported by both scanners and fixed in Debian's
  `3.0.18-1~deb12u2`.
- **Why not others** (details in `TRIAGE.md` → "Why not others"):
  - the three other real nginx CVEs Grype reports would each need more setup to
    prove the fix (TLS certificates and session resumption; an HTTP/3 client, which
    Python's standard library lacks; an async file I/O + SSI setup). CVE-2026-15176
    needed only plain HTTP and comes with a reproducer. I did not read their fixes;
    I stopped once one CVE met every criterion;
  - 24 of the 29 nginx.org advisories for 1.25.5 are reported by no scanner, so a fix
    would not show up in the rescan;
  - bumping packages nginx does not load (e.g. `curl`) is easy but says nothing
    about nginx.

## Drop-in replacement

The image was compared with `nginx:1.25-bookworm`, not built from memory:

- **Config:** `docker image inspect` `.Config` is identical (entrypoint
  `/docker-entrypoint.sh`, `CMD ["nginx", "-g", "daemon off;"]`, port 80/tcp,
  `STOPSIGNAL SIGQUIT`, no `User`/`WorkingDir`, same `ENV`) except the `maintainer`
  label, which names who built this image. `ENV` keeps upstream's values
  (`PKG_RELEASE=1~bookworm`, not our `+echo2`), because scripts may read them.
  `make test` checks this.
- **User:** `nginx`, uid/gid 101, created before the package is installed, as upstream does.
- **Filesystem:** paths, owners, permissions, symlinks (logs to `/dev/stdout` and
  `/dev/stderr`) and file sizes were compared by hand with `find` in both images:
  identical, except the dynamic module `.so` files, 16–24 bytes smaller (we compile
  them ourselves, so the bytes are not identical).
- **Copied from upstream, not compiled:** `docker/docker-entrypoint.sh`,
  `docker/docker-entrypoint.d/*`, `build/debian/nginx.conf` and
  `build/debian/default.conf` are byte-identical copies from the upstream image. They
  are scripts and config, not binaries; the entrypoint's behaviour (including its
  config templates) is part of what users rely on.

## Compatibility

`make test` runs [`test/compat_test.py`](test/compat_test.py) (Python 3 standard
library only). It boots `nginx:1.25-bookworm` and our image as separate containers,
sends both the same requests, and exits non-zero if any response differs.

**"Working correctly" means:** for the same configuration and request, our image
returns the same status code, the same headers with the same values in the same
order, and the same body byte for byte. Only `Date` is ignored, because it differs
between two runs of the same image. Each test also checks the expected result on its
own (a real 304, not two identical 200s), so two images broken the same way do not
"match".

**Covered (29 tests):** the default config (`GET`, `HEAD`, 404, 405, 304 from
`If-None-Match` and `If-Modified-Since`, range requests); a custom config (`return`,
redirects, `rewrite`, gzip, a 1 MiB file, body size limit 413, URI too long 414);
malformed requests over a raw socket, compared byte for byte (bad HTTP version,
missing `Host`, garbage, oversized header); the entrypoint rendering a config
template with an environment variable; and the image metadata (`docker inspect`
config, `nginx -V` configure arguments, clean stop).

**Not covered:** TLS, HTTP/2 and HTTP/3; proxying and caching; loading the dynamic
modules (checked by hand with `nginx -t` at build time only); performance and load;
log output.

**The test can fail:** pointed at `nginx:1.27-bookworm` it reports 28 failures and
exits 1. The fixed CVE is the one case where the images must differ; it is tested
separately by `make cve-test` ([`test/cve-2026-15176.sh`](test/cve-2026-15176.sh)).

Full definition, coverage table and exclusions: [`test/README.md`](test/README.md).

## Rescan and VEX

Both images were scanned with the same scanner versions (Trivy 0.76.2, Grype 0.121.3)
and the same vulnerability databases (16 Nov 2026). Reports in [`scans/`](scans/),
diff in [`scans/DIFF.md`](scans/DIFF.md) (made by `scans/diff.py`).

| Findings | Trivy | Grype |
|---|---:|---:|
| `nginx:1.25-bookworm` (baseline) | 933 | 881 |
| `nginx-rebuild:1.25.5` | 564 | 515 |
| `nginx-rebuild:1.25.5` with VEX | 563 | 514 |

How to read these numbers:

- **Most of the drop is not our work.** Upstream's image was built in May 2024 on
  Debian 12.5; ours starts from a current `debian:bookworm-slim` (12.15), whose packages
  already include Debian's security updates. Most of the ~370 removed findings come
  from that. Our bump's real contribution is the `Depends: libssl3 (>= 3.0.18-1~deb12u2)`
  line: it makes the OpenSSL fix a guarantee, not a coincidence of the build date.
- **The bump:** CVE-2025-15467 is gone from both reports (`libssl3` and `openssl`).
- **The backport:** CVE-2026-15176 is still listed on our image by both scanners. They
  match on the package name and the version `1.25.5`, and cannot see the patch. That
  is what the VEX statement is for.
- **Trivy added 8 nginx findings** on our image and listed none on upstream's. Trivy
  skips packages whose maintainer is nginx.org's packaging address
  ([`dpkg.go` line 80](https://github.com/aquasecurity/trivy/blob/v0.76.2/pkg/fanal/analyzer/pkg/dpkg/dpkg.go#L80),
  [`driver.go` line 36](https://github.com/aquasecurity/trivy/blob/v0.76.2/pkg/detector/ospkg/driver/driver.go#L36)).
  Our package names its real maintainer, so Trivy treats it as Debian's nginx and
  matches Debian's nginx data. Changing only the `Maintainer:` field back to nginx.org's
  makes the 8 disappear (tested). They are the same 8 that Grype already reported on
  upstream: the CVEs were there before, Trivy just did not show them.

**VEX.** [`vex/nginx-CVE-2026-15176.openvex.json`](vex/nginx-CVE-2026-15176.openvex.json)
is an OpenVEX statement: CVE-2026-15176 is `fixed` in our nginx package, identified by
the exact package URL the scanners report
(`pkg:deb/debian/nginx@1.25.5-1~bookworm%2Becho2?arch=amd64&distro=debian-12.15`).
Status `fixed`, not `not_affected`: the vulnerable code was in 1.25.5 and was changed
by the patch. `make vex-scan` rescans with it: Trivy moves the CVE to "Suppressed
Vulnerabilities" ([`scans/vex-trivy.txt`](scans/vex-trivy.txt)), Grype moves it to
`ignoredMatches` ([`scans/vex-grype.json`](scans/vex-grype.json)). The statement only
matches this exact package version on Debian 12.15; a rebuild with a new revision
needs a new statement.

## Residual risk

**What is still there**

- **No more bumps are possible.** Every finding left on the image has no fix in
  Debian 12 as of 16 Nov 2026: Grype 311 "not fixed" + 203 "won't fix" (Debian decided
  not to fix them in bookworm), Trivy 0 of 563 with a fixed version. Lowering these
  further means removing packages or moving to a newer Debian, both of which change
  the image that users rely on.
- **28 other nginx.org advisories cover 1.25.5 and are not patched.** Grype reports 4
  of them (CVE-2026-97205, CVE-2026-97629, CVE-2026-95101, and CVE-2009-4487, which
  Debian rates unimportant); the other 24 are reported by no scanner. A clean scan
  of this image would not mean a safe nginx.
- **nginx 1.25 is an end-of-life branch.** Upstream will not ship fixes for it, so
  every future fix has to be backported by hand.
- **Known scanner noise:** Grype lists CVE-2026-93479, which nginx.org says does not
  affect 1.25.5 (false positive). CVE-2023-44487 (HTTP/2 rapid reset) is listed but
  was not triaged for this version.
- **Not checked:** whether nginx ever calls the OpenSSL CMS code behind
  CVE-2025-15467 (fixed anyway by the bump). Upstream's related hardening commit
  [`3dbce28`](https://github.com/nginx/nginx/commit/3dbce28821179082f27daaa13bf0d5ada548fd20)
  ("Dav: destination validation for COPY and MOVE with alias") is not included; the
  patch holds only the CVE fix.

**Build and supply chain**

- nginx's tarball is checked against a pinned SHA-256 and nginx.org's PGP signature.
  njs has no signed release, so it is checked only by its git commit hash, which is
  weaker. The base image is pinned by digest.
- The build is repeatable, not bit-for-bit reproducible: two builds of the same
  source gave `.deb` files a few hundred bytes apart, and apt installs whatever
  bookworm ships on the day of the build.
- The compatibility test does not cover TLS, HTTP/2/3, proxying or the dynamic
  modules (see "Compatibility").
- The VEX statement matches only `1.25.5-1~bookworm+echo2` on Debian 12.15.

**What I would do next**

1. Move to a supported nginx (1.30.6 or later), which has the fixes for the CVEs
   Grype reports.
2. Until then, backport the three real nginx CVEs Grype reports, each with a reproducer
   and a test for its feature (TLS, HTTP/3, AIO + SSI).
3. Add a `not_affected` VEX statement for the false positive CVE-2026-93479.
4. Pin Debian packages to a snapshot (snapshot.debian.org) so a rebuild installs the
   same libraries.
5. Add TLS, HTTP/2 and module-loading cases to the compatibility test.

## Surprises

- **The scanners barely know this nginx.** Grype matches nginx.org's package by name
  against Debian's nginx data: 5 of the 29 advisories, plus one false positive. Trivy
  shows none on upstream.
- **Labelling the package honestly made 8 CVEs appear** in Trivy (see "Rescan and
  VEX"). I kept the honest label and used VEX instead of faking the maintainer.
- **The reproducer did not crash upstream.** Only the `nginx-debug` log showed the
  request URI being overwritten with zero bytes. Undefined behaviour does not announce
  itself.
- **Severity depends on who you ask.** Grype rates CVE-2026-15176 Critical, nginx.org
  "medium". An OpenSSL CVE both scanners rate Critical is rated Low by OpenSSL
  (32-bit only).
- **The default page's dates matter.** `ETag` and `Last-Modified` are built from file
  time and size. The tarball's html files carry the same date as upstream's image, so
  keeping it (`cp -p`) makes those headers match; the first package lost it.

## With more time / differently

The next steps for security are under "Residual risk". Beyond those:

- Work on a Linux machine from the start. Windows + WSL + Docker Desktop cost time
  (path rewriting, lost shell variables, a misleading exit code).
- Test the measuring tool before trusting it: one false "exit 0" sent me debugging a
  script that was fine.
- Write the compatibility test before building the image, so every build step is
  checked against it as it lands.

## AI usage

I used Claude Code (Anthropic) throughout, as a pair: it proposed steps, wrote drafts
of scripts and text, and ran commands after announcing each one; I approved every
file, decision and commit message before it landed, and asked "why" until I could
explain it myself. Every CVE detail, version, commit hash and checksum in this repo
comes from a primary source (nginx.org, the nginx GitHub repo, Debian's tracker, the
scanners' source), not from the model's memory.

**Where it helped the most**

- Reading source instead of guessing: Trivy's maintainer rule and Grype's VEX matching
  were confirmed in the scanners' code before I relied on them, so VEX worked first time.
- Diffing the nginx tarball against the files saved from upstream's image showed that
  only `nginx.conf` and `conf.d/default.conf` had to be carried in the repo.
- Following CVE-2026-15176 through the 1.25.5 source, and finding the related upstream
  commit `3dbce28` through GitHub's API.
- Drafting the compatibility test, and catching two traps before they caused false
  results (random ports leaking into `Location`, and `make test IMAGE=…` re-tagging
  our own image).

It also made mistakes (a wrong file mode in the first package, a broken exit-code
check); each was caught by checking real output before moving on.
