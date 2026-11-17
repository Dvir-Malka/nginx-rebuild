# Compatibility test

`make test` boots upstream `nginx:1.25-bookworm` and our image
(`nginx-rebuild:1.25.5`, or `make test IMAGE=name:tag`) as separate
containers, sends both the same requests, and fails if any response differs.

- Code: `compat_test.py`, Python 3 standard library only (`unittest`,
  `http.client`, `socket`). Needs Docker and `python3`, nothing to install.
- Run without make: `IMAGE=name:tag python3 test/compat_test.py`
  (`UPSTREAM_IMAGE` overrides the reference image).
- Exit code: 0 if every test passes, 1 otherwise (standard `unittest`).

## What "working correctly" means

For the same configuration and the same request, our image returns:

- the same status code,
- the same headers, with the same values, **in the same order**,
- the same body, byte for byte.

One header is excluded: `Date`. It is the current time, so it differs between
two runs of the *same* image and says nothing about the build. Everything else
must match, including `Server` (version string), `ETag` and `Last-Modified`
(built from the file's modification time and size, so they only match because
the image keeps upstream's file dates), `Content-Length` and `Connection`.

Each test also checks the expected result on its own (for example, a real 304,
not two identical 200s). Otherwise two images broken in the same way would
"match".

## How it works

- Each test class starts one container of each image on a random port of
  `127.0.0.1` and removes both at the end, also when a test fails.
- Custom config and templates are put in with `docker create` + `docker cp` +
  `docker start`, not a bind mount: the files are in place before the
  entrypoint runs, and it behaves the same on Linux, macOS and Docker Desktop.
- Requests always send `Host: localhost`. Otherwise each side would send its
  own random port, and nginx copies the Host into redirect `Location` headers.

## Coverage (29 tests)

| Class | Config | What is compared |
|---|---|---|
| `DefaultConfig` (8) | image default | `GET /`, `HEAD /`, 404 page, `/50x.html`, `POST` to a static file (405), `If-None-Match` and `If-Modified-Since` (304), `Range: bytes=0-99` (206) |
| `CustomConfig` (11) | `fixtures/custom.conf` replaces `conf.d/default.conf` | `return 200` with a custom header, `return 301`, `rewrite` with captures and query string, `rewrite … redirect` (302), gzip with and without `Accept-Encoding` (compressed bytes must match), 1 MiB file and a range of it, body over `client_max_body_size` (413) and under it (200), 10 000-character URI (414) |
| `MalformedRequests` (6) | image default | Raw socket, **full response bytes** compared (minus `Date`): `HTTP/9.9` (505), HTTP/1.1 without `Host` (400), garbage bytes (400), lower-case method (400), 10 KB header (400), plus a valid HTTP/1.0 request as a control (200) |
| `EntrypointTemplate` (1) | `fixtures/templates/` copied to `/etc/nginx/templates`, `TEST_GREETING` set | upstream's entrypoint renders the template with `envsubst`: the variable is filled in and nginx's own `$host` is kept |
| `ImageMetadata` (3) | — | `docker image inspect` `.Config` equal except `Labels`; `nginx -V` configure arguments equal except the build directory in `-ffile-prefix-map`; `docker stop` exits 0 within 5 s on both |

Deliberate exclusions inside these tests:

- `Labels`: our `maintainer` label names who built the image, not upstream.
  It is informational and should be truthful.
- `-ffile-prefix-map=<build dir>`: upstream built in its own build directory,
  we build in `/build`. It only changes file names inside debug information.
- The `built by gcc` and `built with OpenSSL` lines of `nginx -V` are not
  compared: a newer OpenSSL is one of the fixes.

## Proof that it fails

A test that has only ever passed proves little. Pointed at a different nginx:

    IMAGE=nginx:1.27-bookworm python3 test/compat_test.py

it ended with `FAILED (failures=28)` and exit code 1 (17 Nov 2026). The
failure messages name the real differences, for example:

    ('server', 'nginx/1.25.5')  vs  ('server', 'nginx/1.27.5')
    ('etag', 'W/"661e8b67-267"') vs  ('etag', 'W/"67ff9c07-267"')

The only test that passed was `test_graceful_stop`: it checks that each image
stops cleanly, which both do.

Use the script directly for this, not `make test IMAGE=nginx:1.27-bookworm`:
`make test` builds our image first and would tag it with that name.

## What it does not cover

- **The fixed CVE.** For CVE-2026-15176 the two images are *supposed* to
  differ. That case lives in `cve-2026-15176.sh` (`sh test/cve-2026-15176.sh`):
  it passes only if our image logs nginx's alert and upstream's does not.
- HTTP/2, HTTP/3 and TLS: the default image serves plain HTTP/1.1 on port 80.
- Proxying (`proxy_pass`, upstreams), FastCGI, caching.
- Loading the dynamic modules (njs, xslt, geoip, image-filter). These were
  checked by hand at build time with `nginx -t` but are not part of this test.
- Performance, memory use, behaviour under load or with many connections.
- IPv6 listening, other architectures than amd64.
- Log output. Logs differ in timing-dependent ways (count of signal notice
  lines, process IDs), so responses are compared, not logs.
