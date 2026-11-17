#!/bin/bash
# Builds nginx from upstream source inside the builder image.
# Runs as a step of build/Dockerfile.

# Stop at the first error, on any unset variable, and if any part of a pipe fails.
set -euo pipefail

NGINX_VERSION=1.25.5
TARBALL="nginx-${NGINX_VERSION}.tar.gz"

# Version of our package: upstream's package version plus "+echoN". "+echo"
# marks it as our rebuild and sorts higher than the original in dpkg; N goes
# up whenever our binary changes (2: CVE-2026-15176 patch added).
PKG_VERSION="${NGINX_VERSION}-1~bookworm+echo2"

# SHA-256 of the tarball, recorded on 16 Nov 2026 after its PGP signature
# was checked by hand. Pinned so every build uses exactly the same source.
NGINX_SHA256=2fe2294f8af4144e7e842eaea884182a84ee7970e11046ba98194400902bbec0

# Fingerprint of the nginx.org developer key that signed this release
# (Roman Arutyunyan). Pinned so that a different key, even one served by
# nginx.org itself, is not accepted.
NGINX_KEY=43387825DDB1BB97EC36BA5D007C8D7C15D87369

# njs, nginx's JavaScript module, has no release tarball or signature.
# Its 0.8.4 tag points at this commit (GitHub release page and
# `git ls-remote`, checked 17 Nov 2026); the build fails on any other.
NJS_VERSION=0.8.4
NJS_COMMIT=3fb0ee5e907c9a4153d92946c1ef1b96202f883b

echo "== 1. Fetch source, signature and signing key"
curl -fsSLO "https://nginx.org/download/${TARBALL}"
curl -fsSLO "https://nginx.org/download/${TARBALL}.asc"
curl -fsSLO "https://nginx.org/keys/arut.key"
git clone --quiet --depth 1 --branch "${NJS_VERSION}" https://github.com/nginx/njs.git

echo "== 2. Verify"
# Checksum: is this the same file we verified before?
echo "${NGINX_SHA256}  ${TARBALL}" | sha256sum --check -
# Signature: did the pinned key sign it? gpg prints a VALIDSIG status line
# with the signer's fingerprint; grep fails the build if ours is not there.
gpg --import arut.key
gpg --status-fd 1 --verify "${TARBALL}.asc" "${TARBALL}" | grep "VALIDSIG ${NGINX_KEY}"
# njs: the code must be exactly the pinned commit.
test "$(git -C njs rev-parse HEAD)" = "${NJS_COMMIT}"
echo "njs ${NJS_VERSION}: commit ${NJS_COMMIT} OK"

echo "== 3. Unpack"
tar -xzf "${TARBALL}"
ls "nginx-${NGINX_VERSION}"

echo "== 3b. Apply security patches"
# Every file in patches/ is a backported upstream fix, named after its CVE.
# --fuzz=0: a hunk must match the 1.25.5 source exactly, or the build fails,
# so a patch can never land in the wrong place without anyone noticing.
for p in /build/patches/*.patch; do
  echo "applying ${p##*/}"
  patch -d "nginx-${NGINX_VERSION}" -p1 --fuzz=0 < "${p}"
done

echo "== 4. Configure"
cd "nginx-${NGINX_VERSION}"
# The flags below are the ones `nginx -V` prints in nginx:1.25-bookworm, so
# the same modules are compiled in and nginx uses the same paths.
# One change: -ffile-prefix-map names our build directory, not upstream's.
# It keeps the build path out of the debug information in the binary.
# The flags are kept in one bash array because nginx-debug (section 8)
# uses the same list plus --with-debug.
CONFIGURE_FLAGS=(
  --prefix=/etc/nginx
  --sbin-path=/usr/sbin/nginx
  --modules-path=/usr/lib/nginx/modules
  --conf-path=/etc/nginx/nginx.conf
  --error-log-path=/var/log/nginx/error.log
  --http-log-path=/var/log/nginx/access.log
  --pid-path=/var/run/nginx.pid
  --lock-path=/var/run/nginx.lock
  --http-client-body-temp-path=/var/cache/nginx/client_temp
  --http-proxy-temp-path=/var/cache/nginx/proxy_temp
  --http-fastcgi-temp-path=/var/cache/nginx/fastcgi_temp
  --http-uwsgi-temp-path=/var/cache/nginx/uwsgi_temp
  --http-scgi-temp-path=/var/cache/nginx/scgi_temp
  --user=nginx
  --group=nginx
  --with-compat
  --with-file-aio
  --with-threads
  --with-http_addition_module
  --with-http_auth_request_module
  --with-http_dav_module
  --with-http_flv_module
  --with-http_gunzip_module
  --with-http_gzip_static_module
  --with-http_mp4_module
  --with-http_random_index_module
  --with-http_realip_module
  --with-http_secure_link_module
  --with-http_slice_module
  --with-http_ssl_module
  --with-http_stub_status_module
  --with-http_sub_module
  --with-http_v2_module
  --with-http_v3_module
  --with-mail
  --with-mail_ssl_module
  --with-stream
  --with-stream_realip_module
  --with-stream_ssl_module
  --with-stream_ssl_preread_module
  --with-cc-opt="-g -O2 -ffile-prefix-map=$(pwd)=. -fstack-protector-strong -Wformat -Werror=format-security -Wp,-D_FORTIFY_SOURCE=2 -fPIC"
  --with-ld-opt='-Wl,-z,relro -Wl,-z,now -Wl,--as-needed -pie'
)
./configure "${CONFIGURE_FLAGS[@]}"

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

echo "== 8. Compile nginx-debug"
# Upstream's nginx-debug has the same flags plus --with-debug (checked with
# `nginx-debug -V` in nginx:1.25-bookworm). It is built with
# --sbin-path=/usr/sbin/nginx and renamed, as upstream's is.
# make clean deletes the objects of the first build, so nothing is reused.
make clean
./configure "${CONFIGURE_FLAGS[@]}" --with-debug
make -j"$(nproc)"
install -m 755 objs/nginx /pkgroot/usr/sbin/nginx-debug
/pkgroot/usr/sbin/nginx-debug -V

echo "== 9. Compile the dynamic modules"
# Upstream builds the modules in separate configure runs: neither nginx -V
# nor nginx-debug -V lists them. --with-compat (in CONFIGURE_FLAGS) is what
# lets a module built this way load into the main binary.
MODULE_FLAGS=(
  --with-http_xslt_module=dynamic
  --with-http_image_filter_module=dynamic
  --with-http_geoip_module=dynamic
  --with-stream_geoip_module=dynamic
  # njs: built from its own source, the same way as the modules above.
  --add-dynamic-module=/build/njs/nginx
)
mkdir /mods
# For nginx-debug: same flags plus --with-debug, saved as name-debug.so.
make clean
./configure "${CONFIGURE_FLAGS[@]}" --with-debug "${MODULE_FLAGS[@]}"
make -j"$(nproc)" modules
for so in objs/*.so; do
  install -m 644 "${so}" "/mods/$(basename "${so}" .so)-debug.so"
done
# For nginx: the normal flags.
make clean
./configure "${CONFIGURE_FLAGS[@]}" "${MODULE_FLAGS[@]}"
make -j"$(nproc)" modules
install -m 644 objs/*.so /mods/
ls -l /mods

echo "== 10. Compile the njs command-line tool"
# Built from the njs folder with ./configure and make njs, as nginx.org's
# njs install page describes. Same hardening flags as nginx.
# The parentheses run this in a subshell, so the cd does not affect the
# rest of the script.
(
  cd /build/njs
  ./configure \
    --cc-opt="-g -O2 -fstack-protector-strong -Wformat -Werror=format-security -Wp,-D_FORTIFY_SOURCE=2 -fPIC" \
    --ld-opt='-Wl,-z,relro -Wl,-z,now -Wl,--as-needed -pie'
  make -j"$(nproc)" njs
  ./build/njs -v
)

echo "== 11. Package"
# Remove debug information before packaging, as Debian packaging does.
# Upstream's nginx package is 3.4 MB installed; unstripped, ours would be
# about 17 MB. The code that runs does not change.
strip /pkgroot/usr/sbin/nginx /pkgroot/usr/sbin/nginx-debug
strip --strip-unneeded /mods/*.so
strip /build/njs/build/njs
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
# Config files dpkg must not overwrite on upgrade. dpkg also records their
# MD5 when installing, and upstream's entrypoint script
# 10-listen-on-ipv6-by-default.sh compares default.conf with that MD5
# before it enables IPv6. Same list as upstream's package, minus the
# init, default and logrotate files we do not ship.
cat > /pkgroot/DEBIAN/conffiles <<EOF
/etc/nginx/conf.d/default.conf
/etc/nginx/fastcgi_params
/etc/nginx/mime.types
/etc/nginx/nginx.conf
/etc/nginx/scgi_params
/etc/nginx/uwsgi_params
EOF
mkdir /out
# --root-owner-group records every file as owned by root, as upstream's are.
dpkg-deb --build --root-owner-group /pkgroot "/out/nginx_${PKG_VERSION}_${ARCH}.deb"

# The dynamic modules: one package each, with upstream's names and Depends
# (from `dpkg -s nginx-module-*` in nginx:1.25-bookworm). Each depends on
# nginx-r1.25.5, which our nginx package provides, so a module can only be
# installed next to the nginx version it was built for.

# Builds one module .deb from a staged folder.
# Arguments: folder, package name, version, Depends line, description.
build_module_deb() {
  local root="$1" name="$2" version="$3" depends="$4" description="$5"
  mkdir "${root}/DEBIAN"
  cat > "${root}/DEBIAN/control" <<EOF
Package: ${name}
Version: ${version}
Architecture: ${ARCH}
Maintainer: Dvir Malka <357322546+Dvir-Malka@users.noreply.github.com>
Section: httpd
Priority: optional
Depends: ${depends}
Provides: ${name}-r${NGINX_VERSION}
Homepage: https://nginx.org
Description: ${description}
EOF
  dpkg-deb --build --root-owner-group "${root}" "/out/${name}_${version}_${ARCH}.deb"
}

# cp -p keeps the 644 permissions set in section 9.
mkdir -p /pkg-xslt/usr/lib/nginx/modules
cp -p /mods/ngx_http_xslt_filter_module*.so /pkg-xslt/usr/lib/nginx/modules/
build_module_deb /pkg-xslt nginx-module-xslt "${PKG_VERSION}" \
  "libc6 (>= 2.14), libxml2 (>= 2.7.4), libxslt1.1 (>= 1.1.25), nginx-r${NGINX_VERSION}" \
  "nginx ${NGINX_VERSION} xslt dynamic module, rebuilt from upstream source"

mkdir -p /pkg-geoip/usr/lib/nginx/modules
cp -p /mods/ngx_http_geoip_module*.so /mods/ngx_stream_geoip_module*.so /pkg-geoip/usr/lib/nginx/modules/
build_module_deb /pkg-geoip nginx-module-geoip "${PKG_VERSION}" \
  "libc6 (>= 2.14), libgeoip1 (>= 1.6.12), nginx-r${NGINX_VERSION}" \
  "nginx ${NGINX_VERSION} geoip dynamic modules, rebuilt from upstream source"

mkdir -p /pkg-image-filter/usr/lib/nginx/modules
cp -p /mods/ngx_http_image_filter_module*.so /pkg-image-filter/usr/lib/nginx/modules/
build_module_deb /pkg-image-filter nginx-module-image-filter "${PKG_VERSION}" \
  "libc6 (>= 2.14), libgd3 (>= 2.1.0~alpha~), nginx-r${NGINX_VERSION}" \
  "nginx ${NGINX_VERSION} image-filter dynamic module, rebuilt from upstream source"

# njs: upstream's version is nginx's, then njs's, then packaging revision 3
# (NJS_RELEASE=3~bookworm in the upstream image).
mkdir -p /pkg-njs/usr/lib/nginx/modules /pkg-njs/usr/bin
cp -p /mods/ngx_http_js_module*.so /mods/ngx_stream_js_module*.so /pkg-njs/usr/lib/nginx/modules/
install -m 755 /build/njs/build/njs /pkg-njs/usr/bin/njs
build_module_deb /pkg-njs nginx-module-njs "${NGINX_VERSION}+${NJS_VERSION}-3~bookworm+echo2" \
  "libc6 (>= 2.35), libedit2 (>= 3.1-20130611-0), libpcre2-8-0 (>= 10.32), libssl3 (>= 3.0.0), libxml2 (>= 2.7.4), zlib1g (>= 1:1.1.4), nginx-r${NGINX_VERSION}" \
  "nginx ${NGINX_VERSION} njs dynamic modules, rebuilt from upstream source"

# Show the metadata and the file list of every package we built.
for deb in /out/*.deb; do
  dpkg-deb --info "${deb}"
  dpkg-deb --contents "${deb}"
done
