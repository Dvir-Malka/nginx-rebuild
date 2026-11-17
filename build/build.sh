#!/bin/bash
# Builds nginx from upstream source inside the builder image.
# Runs as a step of build/Dockerfile.

# Stop at the first error, on any unset variable, and if any part of a pipe fails.
set -euo pipefail

NGINX_VERSION=1.25.5
TARBALL="nginx-${NGINX_VERSION}.tar.gz"

# Version of our package: upstream's package version plus "+echo1", which
# marks it as our rebuild and sorts higher than the original in dpkg.
PKG_VERSION="${NGINX_VERSION}-1~bookworm+echo1"

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

echo "== 6. Stage the files as they will be laid out in the package"
# DESTDIR makes `make install` copy into /pkgroot instead of the real system.
make install DESTDIR=/pkgroot
# List what was installed, to compare with upstream's `dpkg -L nginx`.
find /pkgroot | sort

echo "== 7. Match the layout of upstream's nginx package"
ETC=/pkgroot/etc/nginx
# Files `make install` adds that upstream's package does not ship.
rm "${ETC}"/*.default "${ETC}/fastcgi.conf" "${ETC}"/koi-utf "${ETC}"/koi-win "${ETC}"/win-utf
rmdir /pkgroot/var/run
# Upstream serves the default pages from /usr/share/nginx/html.
# make install copied them without their dates, so copy them again from
# the source tree with cp -p, which keeps the dates. nginx builds ETag and
# Last-Modified from them, and the tarball's dates equal upstream's.
rm -r "${ETC}/html"
mkdir -p /pkgroot/usr/share/nginx/html
cp -p html/index.html html/50x.html /pkgroot/usr/share/nginx/html/
# nginx.conf and conf.d/default.conf come from nginx's packaging, not from
# the source tarball. Ours are copies of the ones in nginx:1.25-bookworm.
# install -m 644 sets the permissions explicitly: plain cp would copy
# whatever mode the files have on the build machine.
install -m 644 /build/debian/nginx.conf "${ETC}/nginx.conf"
mkdir "${ETC}/conf.d"
install -m 644 /build/debian/default.conf "${ETC}/conf.d/default.conf"
# Empty directories and the symlink that upstream's package creates.
mkdir -p /pkgroot/usr/lib/nginx/modules /pkgroot/var/cache/nginx
ln -s /usr/lib/nginx/modules "${ETC}/modules"
find /pkgroot | sort

echo "== 8. Package"
ARCH="$(dpkg --print-architecture)"
mkdir /pkgroot/DEBIAN
# Depends, Provides, Conflicts and Replaces follow `dpkg -s nginx` in
# nginx:1.25-bookworm. lsb-base is left out: it is only needed by the
# init script, which this package does not ship.
cat > /pkgroot/DEBIAN/control <<EOF
Package: nginx
Version: ${PKG_VERSION}
Architecture: ${ARCH}
Maintainer: Dvir Malka <357322546+Dvir-Malka@users.noreply.github.com>
Section: httpd
Priority: optional
Depends: libc6 (>= 2.34), libcrypt1 (>= 1:4.1.0), libpcre2-8-0 (>= 10.22), libssl3 (>= 3.0.0), zlib1g (>= 1:1.1.4)
Provides: httpd, nginx-r${NGINX_VERSION}
Conflicts: nginx-common, nginx-core
Replaces: nginx-common, nginx-core
Homepage: https://nginx.org
Description: nginx ${NGINX_VERSION} rebuilt from upstream source
 Rebuild of the nginx package found in the nginx:1.25-bookworm image,
 compiled from the nginx.org source tarball.
EOF
mkdir /out
# --root-owner-group records every file as owned by root, as upstream's are.
dpkg-deb --build --root-owner-group /pkgroot "/out/nginx_${PKG_VERSION}_${ARCH}.deb"
# Show the metadata and the file list of the package we just built.
dpkg-deb --info /out/*.deb
dpkg-deb --contents /out/*.deb
