"""Compatibility test: upstream nginx:1.25-bookworm vs our rebuilt image.

Each test sends the same request to both containers and asserts that the
status, headers and body are equal. Run: python3 test/compat_test.py
"""
import http.client
import os
import subprocess
import time
import unittest

# Overridable so reviewers can point the test at other images.
UPSTREAM = os.environ.get("UPSTREAM_IMAGE", "nginx:1.25-bookworm")
OURS = os.environ.get("IMAGE", "nginx-rebuild:1.25.5")

# Headers that differ between two runs of the SAME image (clock), so a
# difference there says nothing about the images.
IGNORED_HEADERS = {"date"}


def docker(*args):
    """Run a docker command, return its stdout, raise if it fails."""
    return subprocess.run(["docker", *args], check=True,
                          capture_output=True, text=True).stdout.strip()


class Container:
    """One nginx container on a free port of 127.0.0.1."""

    def __init__(self, image):
        # "127.0.0.1::80" = Docker picks a free host port, so the two
        # containers never clash and nothing is exposed beyond localhost.
        self.id = docker("run", "-d", "-p", "127.0.0.1::80", image)
        try:
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
        conn = http.client.HTTPConnection("127.0.0.1", self.port, timeout=5)
        try:
            conn.request(method, path, body=body, headers=headers or {})
            resp = conn.getresponse()
            return resp.status, resp.getheaders(), resp.read()
        finally:
            conn.close()

    def remove(self):
        docker("rm", "-f", self.id)


def normalize(headers):
    """Lower-case names, drop ignored headers. Order is kept on purpose:
    nginx writes headers in a fixed order, so a new order is a difference."""
    return [(k.lower(), v) for k, v in headers
            if k.lower() not in IGNORED_HEADERS]


class DefaultConfig(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.upstream = Container(UPSTREAM)
        cls.addClassCleanup(cls.upstream.remove)
        cls.ours = Container(OURS)
        cls.addClassCleanup(cls.ours.remove)

    def assertSameResponse(self, method, path, headers=None, body=None):
        a = self.upstream.request(method, path, headers, body)
        b = self.ours.request(method, path, headers, body)
        self.assertEqual(a[0], b[0], "status differs")
        self.assertEqual(normalize(a[1]), normalize(b[1]), "headers differ")
        self.assertEqual(a[2], b[2], "body differs")
        return a

    def test_get_root(self):
        status, _, body = self.assertSameResponse("GET", "/")
        # Sanity check: two images broken the same way would also "match".
        self.assertEqual(status, 200)
        self.assertIn(b"Welcome to nginx!", body)


if __name__ == "__main__":
    unittest.main(verbosity=2)
