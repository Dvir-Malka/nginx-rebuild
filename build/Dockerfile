# Builder image: the tools needed to compile nginx, nothing else.
# Starts from a clean debian:bookworm-slim, as the brief requires.
FROM debian:bookworm-slim AS builder

# build-essential            gcc, make and the C library headers
# curl, ca-certificates      download the source tarball over HTTPS
# gnupg                      check the tarball's PGP signature
# libssl-dev, libpcre2-dev,  headers for the libraries nginx links to
#   zlib1g-dev               (the same ones `ldd /usr/sbin/nginx` showed upstream)
# libxml2-dev, libxslt1-dev, headers for the dynamic modules: xslt,
#   libgd-dev, libgeoip-dev  image-filter and geoip
# git                        fetch njs, which has no release tarball
# libedit-dev                line editing for the njs command-line tool
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      build-essential ca-certificates curl gnupg \
      libssl-dev libpcre2-dev zlib1g-dev \
      libxml2-dev libxslt1-dev libgd-dev libgeoip-dev \
      git libedit-dev \
 && rm -rf /var/lib/apt/lists/*

WORKDIR /build

# The build script is copied in after the package install above, so that
# editing it does not make Docker reinstall the compiler.
COPY debian/ debian/
COPY build.sh .
RUN bash build.sh

# Second stage: only the .deb. `docker build --output type=local,dest=dist`
# writes this stage's files to dist/ on the host, with no bind mount.
FROM scratch AS export
COPY --from=builder /out/*.deb /
