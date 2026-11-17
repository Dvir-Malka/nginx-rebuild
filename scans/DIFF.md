# Rescan diff: nginx:1.25-bookworm (baseline) vs nginx-rebuild:1.25.5 (fixed)

Made by `scans/diff.py`. Both scans used the same scanner versions and the same
vulnerability database. A finding is one (package, CVE) pair.

## Trivy

| | total | critical | high | medium | low | negligible | unknown |
|---|---:|---:|---:|---:|---:|---:|---:|
| baseline | 933 | 21 | 237 | 347 | 267 | 0 | 61 |
| fixed | 564 | 3 | 141 | 181 | 189 | 0 | 50 |

Removed 377, added 8, unchanged 556.

Our two fixes:

- CVE-2025-15467 (version bump of libssl3): baseline libssl3, openssl; fixed not listed
- CVE-2026-15176 (backport patch to nginx): baseline not listed; fixed nginx

### Added (8)

- nginx CVE-2009-4487 (low)
- nginx CVE-2013-0337 (low)
- nginx CVE-2023-44487 (low)
- nginx CVE-2026-15176 (high)
- nginx CVE-2026-93479 (high)
- nginx CVE-2026-95101 (medium)
- nginx CVE-2026-97205 (high)
- nginx CVE-2026-97629 (medium)

### Removed (377), count per package

- apt: 1
- ca-certificates: 2
- curl: 14
- dpkg: 2
- gcc-12-base: 1
- gpgv: 1
- libabsl20220623: 1
- libaom3: 5
- libapt-pkg6.0: 1
- libavif15: 2
- libbrotli1: 1
- libc-bin: 9
- libc6: 9
- libcap2: 2
- libcurl4: 14
- libde265-0: 14
- libexpat1: 33
- libfreetype6: 1
- libgcc-s1: 1
- libgcrypt20: 1
- libgd3: 1
- libgnutls30: 21
- libgssapi-krb5-2: 7
- libheif1: 3
- libicu72: 1
- libk5crypto3: 7
- libkrb5-3: 7
- libkrb5support0: 7
- liblzma5: 4
- libnghttp2-14: 2
- libpam-modules: 1
- libpam-modules-bin: 1
- libpam-runtime: 1
- libpam0g: 1
- libpcre2-8-0: 7
- libpng16-16: 12
- libsasl2-2: 1
- libsasl2-modules-db: 1
- libssh2-1: 6
- libssl3: 48
- libstdc++6: 1
- libsystemd0: 7
- libtasn1-6: 1
- libtiff6: 9
- libudev1: 7
- libxml2: 21
- libxslt1.1: 5
- login: 2
- openssl: 48
- passwd: 2
- perl-base: 16
- sed: 1
- tzdata: 3

## Grype

| | total | critical | high | medium | low | negligible | unknown |
|---|---:|---:|---:|---:|---:|---:|---:|
| baseline | 881 | 59 | 304 | 298 | 43 | 139 | 38 |
| fixed | 515 | 24 | 148 | 150 | 21 | 136 | 36 |

Removed 366, added 0, unchanged 515.

Our two fixes:

- CVE-2025-15467 (version bump of libssl3): baseline libssl3, openssl; fixed not listed
- CVE-2026-15176 (backport patch to nginx): baseline nginx; fixed nginx

### Added (0)

- none

### Removed (366), count per package

- apt: 1
- curl: 14
- dpkg: 2
- gcc-12-base: 1
- gpgv: 1
- libabsl20220623: 1
- libaom3: 5
- libapt-pkg6.0: 1
- libavif15: 2
- libbrotli1: 1
- libc-bin: 9
- libc6: 9
- libcap2: 2
- libcurl4: 14
- libde265-0: 12
- libexpat1: 33
- libfreetype6: 1
- libgcc-s1: 1
- libgcrypt20: 1
- libgd3: 1
- libgnutls30: 21
- libgssapi-krb5-2: 7
- libheif1: 3
- libicu72: 1
- libk5crypto3: 7
- libkrb5-3: 7
- libkrb5support0: 7
- liblzma5: 2
- libnghttp2-14: 2
- libpam-modules: 1
- libpam-modules-bin: 1
- libpam-runtime: 1
- libpam0g: 1
- libpcre2-8-0: 7
- libpng16-16: 12
- libsasl2-2: 1
- libsasl2-modules-db: 1
- libssh2-1: 6
- libssl3: 48
- libstdc++6: 1
- libsystemd0: 7
- libtasn1-6: 1
- libtiff6: 9
- libudev1: 7
- libxml2: 20
- libxslt1.1: 4
- login: 2
- openssl: 48
- passwd: 2
- perl-base: 16
- sed: 1
