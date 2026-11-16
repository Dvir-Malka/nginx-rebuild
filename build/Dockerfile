# Builder image: the tools needed to compile nginx, nothing else.
# Starts from a clean debian:bookworm-slim, as the brief requires.
FROM debian:bookworm-slim AS builder

# build-essential            gcc, make and the C library headers
# curl, ca-certificates      download the source tarball over HTTPS
# gnupg                      check the tarball's PGP signature
# libssl-dev, libpcre2-dev,  headers for the libraries nginx links to
#   zlib1g-dev               (the same ones `ldd /usr/sbin/nginx` showed upstream)
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      build-essential ca-certificates curl gnupg \
      libssl-dev libpcre2-dev zlib1g-dev \
 && rm -rf /var/lib/apt/lists/*

WORKDIR /build
