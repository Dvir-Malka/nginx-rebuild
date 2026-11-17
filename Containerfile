# Final image: a drop-in replacement for nginx:1.25-bookworm, built from our
# own .debs (make deb writes them to dist/). Each step mirrors upstream's
# Dockerfile as shown by `docker history nginx:1.25-bookworm`.

# Clean Debian 12 base, pinned by digest so every build starts from the same files.
FROM debian:bookworm-slim@sha256:734a72b3d6142a71993b4bc580ca01d8ca687f77a2c422d96a961d3376b179bc

# Changed on purpose: NGINX did not build this image. Nothing reads this label.
LABEL maintainer="Dvir Malka <357322546+Dvir-Malka@users.noreply.github.com>"

# Same names and values as upstream: scripts and child images may read them.
ENV NGINX_VERSION=1.25.5
ENV NJS_VERSION=0.8.4
ENV NJS_RELEASE=3~bookworm
ENV PKG_RELEASE=1~bookworm

# dist/ is mounted only while this step runs, so the .deb files do not stay in a layer.
RUN --mount=type=bind,source=dist,target=/tmp/debs \
    set -x \
    # User and group first, with upstream's exact flags: uid/gid 101 must match
    # so file ownership on mounted volumes behaves the same.
    && groupadd --system --gid 101 nginx \
    && useradd --system --gid nginx --no-create-home --home /nonexistent \
       --comment "nginx user" --shell /bin/false --uid 101 nginx \
    && apt-get update \
    # apt (not dpkg) so it also installs the libraries our packages depend on,
    # e.g. the fixed libssl3 from bookworm-security.
    && apt-get install --no-install-recommends --no-install-suggests -y \
       /tmp/debs/*.deb ca-certificates gettext-base curl \
    && rm -rf /var/lib/apt/lists/* \
    # Docker collects a container's stdout/stderr as its logs.
    && ln -sf /dev/stdout /var/log/nginx/access.log \
    && ln -sf /dev/stderr /var/log/nginx/error.log \
    && mkdir /docker-entrypoint.d

# Shell scripts copied unchanged from upstream's image. --chmod because
# docker-entrypoint.sh skips scripts without the executable bit, and Windows
# checkouts do not keep it.
COPY --chmod=755 docker/docker-entrypoint.sh /
COPY --chmod=755 docker/docker-entrypoint.d/ /docker-entrypoint.d/

ENTRYPOINT ["/docker-entrypoint.sh"]
EXPOSE 80
STOPSIGNAL SIGQUIT
CMD ["nginx", "-g", "daemon off;"]
