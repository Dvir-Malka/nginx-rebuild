#!/bin/bash
# Builds nginx from upstream source inside the builder image.
# Runs as a step of build/Dockerfile.

# Stop at the first error, on any unset variable, and if any part of a pipe fails.
set -euo pipefail

NGINX_VERSION=1.25.5
TARBALL="nginx-${NGINX_VERSION}.tar.gz"

# SHA-256 of the tarball, recorded on 16 Nov 2026 after its PGP signature
# was checked by hand. Pinned so every build uses exactly the same source.
NGINX_SHA256=2fe2294f8af4144e7e842eaea884182a84ee7970e11046ba98194400902bbec0

# Fingerprint of the nginx.org developer key that signed this release
# (Roman Arutyunyan). Pinned so that a different key, even one served by
# nginx.org itself, is not accepted.
NGINX_KEY=43387825DDB1BB97EC36BA5D007C8D7C15D87369

echo "== 1. Fetch source, signature and signing key"
curl -fsSLO "https://nginx.org/download/${TARBALL}"
curl -fsSLO "https://nginx.org/download/${TARBALL}.asc"
curl -fsSLO "https://nginx.org/keys/arut.key"

echo "== 2. Verify"
# Checksum: is this the same file we verified before?
echo "${NGINX_SHA256}  ${TARBALL}" | sha256sum --check -
# Signature: did the pinned key sign it? gpg prints a VALIDSIG status line
# with the signer's fingerprint; grep fails the build if ours is not there.
gpg --import arut.key
gpg --status-fd 1 --verify "${TARBALL}.asc" "${TARBALL}" | grep "VALIDSIG ${NGINX_KEY}"

echo "== 3. Unpack"
tar -xzf "${TARBALL}"
ls "nginx-${NGINX_VERSION}"
