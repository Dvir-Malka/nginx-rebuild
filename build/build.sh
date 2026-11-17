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

echo "== 4. Configure"
cd "nginx-${NGINX_VERSION}"
# The flags below are the ones `nginx -V` prints in nginx:1.25-bookworm, so
# the same modules are compiled in and nginx uses the same paths.
# One change: -ffile-prefix-map names our build directory, not upstream's.
# It keeps the build path out of the debug information in the binary.
./configure \
  --prefix=/etc/nginx \
  --sbin-path=/usr/sbin/nginx \
  --modules-path=/usr/lib/nginx/modules \
  --conf-path=/etc/nginx/nginx.conf \
  --error-log-path=/var/log/nginx/error.log \
  --http-log-path=/var/log/nginx/access.log \
  --pid-path=/var/run/nginx.pid \
  --lock-path=/var/run/nginx.lock \
  --http-client-body-temp-path=/var/cache/nginx/client_temp \
  --http-proxy-temp-path=/var/cache/nginx/proxy_temp \
  --http-fastcgi-temp-path=/var/cache/nginx/fastcgi_temp \
  --http-uwsgi-temp-path=/var/cache/nginx/uwsgi_temp \
  --http-scgi-temp-path=/var/cache/nginx/scgi_temp \
  --user=nginx \
  --group=nginx \
  --with-compat \
  --with-file-aio \
  --with-threads \
  --with-http_addition_module \
  --with-http_auth_request_module \
  --with-http_dav_module \
  --with-http_flv_module \
  --with-http_gunzip_module \
  --with-http_gzip_static_module \
  --with-http_mp4_module \
  --with-http_random_index_module \
  --with-http_realip_module \
  --with-http_secure_link_module \
  --with-http_slice_module \
  --with-http_ssl_module \
  --with-http_stub_status_module \
  --with-http_sub_module \
  --with-http_v2_module \
  --with-http_v3_module \
  --with-mail \
  --with-mail_ssl_module \
  --with-stream \
  --with-stream_realip_module \
  --with-stream_ssl_module \
  --with-stream_ssl_preread_module \
  --with-cc-opt="-g -O2 -ffile-prefix-map=$(pwd)=. -fstack-protector-strong -Wformat -Werror=format-security -Wp,-D_FORTIFY_SOURCE=2 -fPIC" \
  --with-ld-opt='-Wl,-z,relro -Wl,-z,now -Wl,--as-needed -pie'

echo "== 5. Compile"
# One compile job per CPU core.
make -j"$(nproc)"
# Print the version and flags of the binary we just built.
./objs/nginx -V
