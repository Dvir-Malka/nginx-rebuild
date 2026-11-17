"""Compatibility test: upstream nginx:1.25-bookworm vs our rebuilt image.

Each test sends the same request to both containers and asserts that the
status, headers and body are equal. Run: python3 test/compat_test.py
"""
import http.client
import json
import os
import re
import shutil
import socket
import subprocess
import tempfile
import time
import unittest

# Overridable so reviewers can point the test at other images.
UPSTREAM = os.environ.get("UPSTREAM_IMAGE", "nginx:1.25-bookworm")
OURS = os.environ.get("IMAGE", "nginx-rebuild:1.25.5")

FIXTURES = os.path.join(os.path.dirname(os.path.abspath(__file__)), "fixtures")

# Headers that differ between two runs of the SAME image (clock), so a
# difference there says nothing about the images.
IGNORED_HEADERS = {"date"}


def docker(*args):
    """Run a docker command, return its stdout, raise if it fails."""
    return subprocess.run(["docker", *args], check=True,
                          capture_output=True, text=True).stdout.strip()


class Container:
    """One nginx container on a free port of 127.0.0.1."""

    def __init__(self, image, files=(), env=None):
        # create + cp + start instead of a bind mount: the files are in place
        # before the entrypoint runs, and it works the same on Linux, macOS
        # and Docker Desktop, with no host path rewriting.
        # "127.0.0.1::80" = Docker picks a free host port, so the two
        # containers never clash and nothing is exposed beyond localhost.
        env_flags = [f"--env={k}={v}" for k, v in (env or {}).items()]
        self.id = docker("create", "-p", "127.0.0.1::80", *env_flags, image)
        try:
            for src, dest in files:
                docker("cp", src, f"{self.id}:{dest}")
            docker("start", self.id)
            # "docker port" prints e.g. "127.0.0.1:49153".
            self.port = int(docker("port", self.id, "80/tcp").rsplit(":", 1)[1])
            self.wait_ready()
        except Exception:
            self.remove()  # never leave a container behind
            raise

    def wait_ready(self, timeout=15):
        # The entrypoint scripts run before nginx listens, so poll.
        deadline = time.time() + timeout
        while time.time() < deadline:
            try:
                self.request("GET", "/")
                return
            except OSError:
                time.sleep(0.2)
        raise RuntimeError(f"{self.id[:12]} not ready after {timeout}s")

    def request(self, method, path, headers=None, body=None):
        # Fixed Host: otherwise each side sends its own random port, and
        # nginx copies the Host into redirect Location headers.
        headers = {"Host": "localhost", **(headers or {})}
        conn = http.client.HTTPConnection("127.0.0.1", self.port, timeout=5)
        try:
            conn.request(method, path, body=body, headers=headers)
            resp = conn.getresponse()
            return resp.status, resp.getheaders(), resp.read()
        finally:
            conn.close()

    def raw(self, data):
        """Send bytes exactly as given and return all bytes nginx sends back
        until it closes the connection. Needed for requests that http.client
        would refuse to send or would quietly fix."""
        with socket.create_connection(("127.0.0.1", self.port), timeout=5) as s:
            s.sendall(data)
            chunks = []
            while chunk := s.recv(65536):
                chunks.append(chunk)
        return b"".join(chunks)

    def remove(self):
        docker("rm", "-f", self.id)


def normalize(headers):
    """Lower-case names, drop ignored headers. Order is kept on purpose:
    nginx writes headers in a fixed order, so a new order is a difference."""
    return [(k.lower(), v) for k, v in headers
            if k.lower() not in IGNORED_HEADERS]


def strip_date(raw):
    """Remove the Date header line from a raw response (clock, see above)."""
    return re.sub(rb"\r\nDate: [^\r]*", b"", raw)


class CompareBase(unittest.TestCase):
    """Starts both images with the same files and env; no tests itself."""
    files = ()
    env = {}

    @classmethod
    def setUpClass(cls):
        cls.upstream = Container(UPSTREAM, cls.files, cls.env)
        cls.addClassCleanup(cls.upstream.remove)
        cls.ours = Container(OURS, cls.files, cls.env)
        cls.addClassCleanup(cls.ours.remove)

    def assertSameResponse(self, method, path, headers=None, body=None):
        a = self.upstream.request(method, path, headers, body)
        b = self.ours.request(method, path, headers, body)
        self.assertEqual(a[0], b[0], "status differs")
        self.assertEqual(normalize(a[1]), normalize(b[1]), "headers differ")
        self.assertEqual(a[2], b[2], "body differs")
        return a


class DefaultConfig(CompareBase):
    def test_get_root(self):
        status, _, body = self.assertSameResponse("GET", "/")
        # Sanity check: two images broken the same way would also "match".
        self.assertEqual(status, 200)
        self.assertIn(b"Welcome to nginx!", body)

    def test_head_root(self):
        status, _, body = self.assertSameResponse("HEAD", "/")
        self.assertEqual(status, 200)
        self.assertEqual(body, b"")  # HEAD never has a body

    def test_not_found(self):
        status, _, body = self.assertSameResponse("GET", "/nope")
        self.assertEqual(status, 404)
        # nginx's built-in error page names its version; must match too.
        self.assertIn(b"nginx/1.25.5", body)

    def test_50x_page(self):
        status, _, _ = self.assertSameResponse("GET", "/50x.html")
        self.assertEqual(status, 200)

    def test_post_to_static_file(self):
        # nginx's static file handler only serves GET and HEAD.
        status, _, _ = self.assertSameResponse("POST", "/", body=b"x=1")
        self.assertEqual(status, 405)

    def test_if_none_match(self):
        # ETag = file mtime + size: matches only if we kept upstream's dates.
        etag = dict(normalize(self.upstream.request("GET", "/")[1]))["etag"]
        status, _, body = self.assertSameResponse(
            "GET", "/", {"If-None-Match": etag})
        self.assertEqual(status, 304)
        self.assertEqual(body, b"")

    def test_if_modified_since(self):
        lm = dict(normalize(self.upstream.request("GET", "/")[1]))["last-modified"]
        status, _, _ = self.assertSameResponse(
            "GET", "/", {"If-Modified-Since": lm})
        self.assertEqual(status, 304)

    def test_range(self):
        status, headers, body = self.assertSameResponse(
            "GET", "/", {"Range": "bytes=0-99"})
        self.assertEqual(status, 206)
        self.assertEqual(dict(normalize(headers))["content-range"], "bytes 0-99/615")
        self.assertEqual(len(body), 100)


class CustomConfig(CompareBase):
    @classmethod
    def setUpClass(cls):
        # 1 MiB file made at test time, so no large file sits in the repo.
        tmp = tempfile.mkdtemp()
        cls.addClassCleanup(shutil.rmtree, tmp)
        big = os.path.join(tmp, "big.bin")
        with open(big, "wb") as f:
            f.write(bytes(range(256)) * 4096)
        cls.files = [
            (os.path.join(FIXTURES, "custom.conf"), "/etc/nginx/conf.d/default.conf"),
            (big, "/usr/share/nginx/html/big.bin"),
        ]
        super().setUpClass()

    def header(self, headers, name):
        return dict(normalize(headers)).get(name)

    def test_return_200_with_custom_header(self):
        status, headers, body = self.assertSameResponse("GET", "/hello")
        self.assertEqual((status, body), (200, b"hello\n"))
        self.assertEqual(self.header(headers, "x-test"), "echo")

    def test_redirect_301(self):
        status, headers, _ = self.assertSameResponse("GET", "/old")
        self.assertEqual(status, 301)
        self.assertEqual(self.header(headers, "location"), "http://localhost/new")

    def test_rewrite_captures_and_query(self):
        status, _, body = self.assertSameResponse("GET", "/rw/abc/42?x=1")
        self.assertEqual(status, 200)
        self.assertEqual(body, b"uri=/echo args=name=abc&id=42&x=1\n")

    def test_rewrite_redirect(self):
        status, headers, _ = self.assertSameResponse("GET", "/go/there")
        self.assertEqual(status, 302)
        self.assertEqual(self.header(headers, "location"),
                         "http://localhost/hello?from=there")

    def test_gzip_when_asked(self):
        _, headers, _ = self.assertSameResponse(
            "GET", "/index.html", {"Accept-Encoding": "gzip"})
        self.assertEqual(self.header(headers, "content-encoding"), "gzip")

    def test_no_gzip_when_not_asked(self):
        _, headers, _ = self.assertSameResponse("GET", "/index.html")
        self.assertIsNone(self.header(headers, "content-encoding"))

    def test_large_file(self):
        status, _, body = self.assertSameResponse("GET", "/big.bin")
        self.assertEqual((status, len(body)), (200, 1048576))

    def test_range_on_large_file(self):
        status, headers, body = self.assertSameResponse(
            "GET", "/big.bin", {"Range": "bytes=1000-1999"})
        self.assertEqual(status, 206)
        self.assertEqual(self.header(headers, "content-range"),
                         "bytes 1000-1999/1048576")
        self.assertEqual(len(body), 1000)

    def test_body_over_limit(self):
        status, _, _ = self.assertSameResponse("POST", "/upload", body=b"a" * 2048)
        self.assertEqual(status, 413)

    def test_body_under_limit(self):
        status, _, body = self.assertSameResponse("POST", "/upload", body=b"a" * 512)
        self.assertEqual((status, body), (200, b"got 512 bytes\n"))

    def test_very_long_uri(self):
        # Default large_client_header_buffers is 8k, so 10k of URI is too long.
        status, _, _ = self.assertSameResponse("GET", "/" + "a" * 10000)
        self.assertEqual(status, 414)


class MalformedRequests(CompareBase):
    """Broken requests over a raw socket; the full response bytes must match."""

    def assertSameRaw(self, data):
        a = strip_date(self.upstream.raw(data))
        b = strip_date(self.ours.raw(data))
        self.assertEqual(a, b, "raw response differs")
        return a

    def test_http10_without_host(self):
        # Valid: HTTP/1.0 does not require Host. Proves the raw path works.
        resp = self.assertSameRaw(b"GET / HTTP/1.0\r\n\r\n")
        self.assertTrue(resp.startswith(b"HTTP/1.1 200 OK\r\n"))

    def test_unknown_http_version(self):
        resp = self.assertSameRaw(b"GET / HTTP/9.9\r\nHost: localhost\r\n\r\n")
        self.assertTrue(resp.startswith(b"HTTP/1.1 505 "))

    def test_http11_without_host(self):
        # HTTP/1.1 makes Host mandatory.
        resp = self.assertSameRaw(b"GET / HTTP/1.1\r\n\r\n")
        self.assertTrue(resp.startswith(b"HTTP/1.1 400 "))

    def test_garbage_bytes(self):
        resp = self.assertSameRaw(b"\x00\x01\x02 not http at all\r\n\r\n")
        self.assertTrue(resp.startswith(b"HTTP/1.1 400 "))

    def test_lowercase_method(self):
        # nginx accepts only upper-case methods.
        resp = self.assertSameRaw(b"get / HTTP/1.1\r\nHost: localhost\r\n\r\n")
        self.assertTrue(resp.startswith(b"HTTP/1.1 400 "))

    def test_oversized_header(self):
        # One 10 KB header line is larger than the 8k header buffer.
        req = (b"GET / HTTP/1.1\r\nHost: localhost\r\nX-Big: "
               + b"a" * 10000 + b"\r\n\r\n")
        resp = self.assertSameRaw(req)
        self.assertTrue(resp.startswith(b"HTTP/1.1 400 "))
        self.assertIn(b"Request Header Or Cookie Too Large", resp)


class EntrypointTemplate(CompareBase):
    """Upstream's entrypoint turns /etc/nginx/templates/*.template into
    config at start, filling in environment variables with envsubst."""
    # docker cp of a folder creates /etc/nginx/templates (not in the image).
    files = [(os.path.join(FIXTURES, "templates"), "/etc/nginx/templates")]
    env = {"TEST_GREETING": "hello-from-env"}

    def test_template_rendered_with_env(self):
        status, _, body = self.assertSameResponse(
            "GET", "/", {"Host": "templated.test"})
        self.assertEqual((status, body),
                         (200, b"hello-from-env from templated.test\n"))


def inspect_config(image):
    """The image's run settings (docker image inspect .Config) as a dict."""
    return json.loads(docker("image", "inspect", "--format", "{{json .Config}}", image))


def configure_arguments(image):
    """The 'configure arguments:' line of nginx -V (printed on stderr)."""
    out = subprocess.run(["docker", "run", "--rm", "--entrypoint", "nginx", image, "-V"],
                         check=True, capture_output=True, text=True).stderr
    line = next(l for l in out.splitlines() if l.startswith("configure arguments:"))
    # The build directory differs (upstream's builder vs our /build); it only
    # changes file names inside debug info, not how nginx behaves.
    return re.sub(r"-ffile-prefix-map=[^ ']*", "-ffile-prefix-map=<builddir>", line)


class ImageMetadata(unittest.TestCase):
    """The drop-in contract that docker run takes from the image itself."""

    def test_config_equal(self):
        a, b = inspect_config(UPSTREAM), inspect_config(OURS)
        # Labels are informational. Our maintainer label names us, not
        # upstream, on purpose: a label should be truthful.
        a.pop("Labels", None)
        b.pop("Labels", None)
        self.assertEqual(a, b)
        # Sanity: the fields the brief names are really there.
        self.assertEqual(a["Entrypoint"], ["/docker-entrypoint.sh"])
        self.assertIn("80/tcp", a["ExposedPorts"])

    def test_configure_arguments_equal(self):
        self.assertEqual(configure_arguments(UPSTREAM), configure_arguments(OURS))

    def test_graceful_stop(self):
        # docker stop sends the image's StopSignal (SIGQUIT = finish open
        # requests, then exit) and kills the container after 10 s.
        for image in (UPSTREAM, OURS):
            with self.subTest(image=image):
                c = Container(image)
                try:
                    start = time.time()
                    docker("stop", c.id)
                    took = time.time() - start
                    code = docker("inspect", "--format", "{{.State.ExitCode}}", c.id)
                finally:
                    c.remove()
                self.assertEqual(code, "0")
                self.assertLess(took, 5)


if __name__ == "__main__":
    unittest.main(verbosity=2)
