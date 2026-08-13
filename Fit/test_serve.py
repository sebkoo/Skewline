"""Tests for the local endpoint.

Every server binds port 0 and the bound port is read back: a test that
races for a fixed port is a flake generator, and this suite's whole value
is that a red test means something.

Fixtures are artifacts written by `fit.write_artifact` into a temporary
directory, plus the committed `Fit/model.json`. No capture-derived file is
touched -- observation exports and containers stay local, as registered.
"""

import contextlib
import http.client
import inspect
import json
import os
import tempfile
import threading
import unittest

import fit
import serve

HERE = os.path.dirname(os.path.abspath(__file__))
COMMITTED_ARTIFACT = os.path.join(HERE, "model.json")


@contextlib.contextmanager
def running(artifact_path):
    server = serve.ModelServer((serve.BIND_HOST, 0), artifact_path, log_requests=False)
    # A short poll interval only shortens how long `shutdown` waits for the
    # loop to notice; the default 0.5 s would tax the gate once per server.
    thread = threading.Thread(
        target=server.serve_forever, kwargs={"poll_interval": 0.01}, daemon=True
    )
    thread.start()
    try:
        yield server.server_address[1]
    finally:
        server.shutdown()
        server.server_close()
        thread.join(timeout=5)


def request(port, method, path, body=None):
    """One request, one connection. Bodies stay small on purpose: this
    exercises the router, not the kernel's socket buffering."""
    connection = http.client.HTTPConnection(serve.BIND_HOST, port, timeout=5)
    try:
        connection.request(method, path, body=body)
        response = connection.getresponse()
        return response.status, dict(response.getheaders()), response.read()
    finally:
        connection.close()


def planted_artifact():
    """A small `skewline-fit/1` with one adopted and one refused class --
    the mixed outcome the real fit produced."""
    return {
        "schema": fit.ARTIFACT_SCHEMA,
        "estimand": fit.ESTIMAND,
        "units": fit.UNITS,
        "outsideDomain": fit.OUTSIDE_DOMAIN,
        "depthDomain": list(fit.DEPTH_DOMAIN),
        "trainedOn": ["PLANTED"],
        "export": [{"session": "PLANTED", "decimation": 64}],
        "classes": {
            "low": {"verdict": "adopted", "form": "quadratic",
                    "coefficients": {"a": 0.02, "b": 0.01}, "folds": []},
            "medium": {"verdict": "adopted", "form": "quadratic",
                       "coefficients": {"a": 0.01, "b": 0.003}, "folds": []},
            "high": {"verdict": "refused", "folds": [],
                     "table": {"edges": list(fit.BAND_EDGES),
                               "medians": [0.003, 0.004, 0.006, 0.009]}},
        },
    }


@contextlib.contextmanager
def artifact_file(payload=None, raw=None):
    with tempfile.TemporaryDirectory() as directory:
        path = os.path.join(directory, "model.json")
        if raw is not None:
            with open(path, "w", encoding="utf-8") as handle:
                handle.write(raw)
        elif payload is not None:
            fit.write_artifact(path, payload)
        yield path


class TheModelEndpoint(unittest.TestCase):
    def test_serves_the_bytes_write_artifact_writes(self):
        # The property at its registered scope: the artifact was produced
        # by `write_artifact`, so the response is byte-for-byte the file.
        with artifact_file(planted_artifact()) as path, running(path) as port:
            status, headers, body = request(port, "GET", serve.MODEL_PATH)
            with open(path, "rb") as handle:
                on_disk = handle.read()
        self.assertEqual(status, 200)
        self.assertEqual(headers["Content-Type"], "application/json")
        self.assertEqual(body, on_disk)

    def test_the_committed_artifact_serves_and_round_trips(self):
        with running(COMMITTED_ARTIFACT) as port:
            status, _, body = request(port, "GET", serve.MODEL_PATH)
        self.assertEqual(status, 200)
        served = json.loads(body)
        self.assertEqual(served, fit.read_artifact(COMMITTED_ARTIFACT))
        with open(COMMITTED_ARTIFACT, "rb") as handle:
            self.assertEqual(body, handle.read())

    def test_the_contract_rides_the_response(self):
        # A consumer must be able to answer "no model here" outside the
        # domain, and must not read the estimand as a single-reading sigma.
        with running(COMMITTED_ARTIFACT) as port:
            _, _, body = request(port, "GET", serve.MODEL_PATH)
        served = json.loads(body)
        self.assertEqual(served["schema"], fit.ARTIFACT_SCHEMA)
        self.assertEqual(served["units"], "meters")
        self.assertEqual(served["outsideDomain"], "refuse")
        self.assertEqual(served["depthDomain"], [0.5, 5.0])
        self.assertIn("pairwise", served["estimand"])

    def test_the_refusal_keeps_its_teeth_across_the_wire(self):
        # v0.6 refused the high class. A consumer cannot be handed
        # coefficients that do not exist.
        with running(COMMITTED_ARTIFACT) as port:
            _, _, body = request(port, "GET", serve.MODEL_PATH)
        high = json.loads(body)["classes"]["high"]
        self.assertEqual(high["verdict"], "refused")
        self.assertIn("table", high)
        self.assertNotIn("coefficients", high)


class WhenThereIsNoModel(unittest.TestCase):
    def test_missing_artifact_is_503_and_the_fit_needs_no_restart(self):
        with artifact_file() as path, running(path) as port:
            status, _, body = request(port, "GET", serve.MODEL_PATH)
            self.assertEqual(status, 503)
            self.assertEqual(json.loads(body)["error"], serve.NO_MODEL)

            # The artifact is re-read per request: a fit landing while the
            # service runs is served without a restart.
            fit.write_artifact(path, planted_artifact())
            status, _, body = request(port, "GET", serve.MODEL_PATH)
        self.assertEqual(status, 200)
        self.assertEqual(json.loads(body)["schema"], fit.ARTIFACT_SCHEMA)

    def test_a_foreign_artifact_is_500_and_never_proxied(self):
        with artifact_file(raw='{"schema": "something-else/9"}\n') as path, \
                running(path) as port:
            status, _, body = request(port, "GET", serve.MODEL_PATH)
        self.assertEqual(status, 500)
        self.assertEqual(json.loads(body)["error"], serve.BAD_ARTIFACT)
        self.assertNotIn("something-else", json.loads(body)["error"])

    def test_unparseable_json_is_500(self):
        with artifact_file(raw="{not json\n") as path, running(path) as port:
            status, _, body = request(port, "GET", serve.MODEL_PATH)
        self.assertEqual(status, 500)
        self.assertEqual(json.loads(body)["error"], serve.BAD_ARTIFACT)


class TheWireRunsOneWay(unittest.TestCase):
    def test_upload_methods_are_refused(self):
        # The privacy decision, enforced by the router rather than promised.
        with artifact_file(planted_artifact()) as path, running(path) as port:
            for method in ("POST", "PUT", "PATCH", "DELETE"):
                with self.subTest(method=method):
                    status, headers, body = request(
                        port, method, serve.MODEL_PATH, body=b'{"upload":"no"}'
                    )
                    self.assertEqual(status, 405)
                    self.assertEqual(headers["Allow"], "GET, HEAD")
                    self.assertEqual(
                        json.loads(body)["error"], serve.METHOD_NOT_ALLOWED
                    )

    def test_no_route_reads_a_request_body(self):
        # Mechanical rather than observational, and deliberately so: the
        # invariant is the absence of a body read anywhere in the module,
        # which a status code cannot witness. Adding one puts `rfile` in
        # the source and turns this red.
        self.assertNotIn("rfile", inspect.getsource(serve))

    def test_there_is_no_query_surface(self):
        # A per-point query would send the client's depths up. Exact path
        # matching is what makes its absence mechanical.
        with running(COMMITTED_ARTIFACT) as port:
            status, _, body = request(
                port, "GET", f"{serve.MODEL_PATH}?class=high&depth=2.0"
            )
        self.assertEqual(status, 404)
        self.assertEqual(json.loads(body)["error"], serve.NO_SUCH_ENDPOINT)

    def test_the_bind_host_is_loopback(self):
        self.assertEqual(serve.BIND_HOST, "127.0.0.1")


class TheEnvelope(unittest.TestCase):
    def test_an_unknown_path_is_404(self):
        with running(COMMITTED_ARTIFACT) as port:
            status, _, body = request(port, "GET", "/model")
        self.assertEqual(status, 404)
        self.assertEqual(json.loads(body)["error"], serve.NO_SUCH_ENDPOINT)

    def test_head_conforms(self):
        # RFC 9110 section 9.1: GET and HEAD are the two a general-purpose
        # server must support. HEAD carries GET's status and headers with
        # no body -- `curl -I` is the first thing a reader tries.
        with running(COMMITTED_ARTIFACT) as port:
            get_status, _, get_body = request(port, "GET", serve.MODEL_PATH)
            status, headers, body = request(port, "HEAD", serve.MODEL_PATH)
            self.assertEqual(status, get_status)
            self.assertEqual(int(headers["Content-Length"]), len(get_body))
            self.assertEqual(body, b"")

            status, _, body = request(port, "HEAD", "/nowhere")
        self.assertEqual(status, 404)
        self.assertEqual(body, b"")

    def test_every_error_body_carries_a_registered_code(self):
        with artifact_file() as missing, running(missing) as port:
            seen = set()
            for method, path, body in (
                ("GET", serve.MODEL_PATH, None),          # 503 no-model
                ("GET", "/nowhere", None),                # 404
                ("POST", serve.MODEL_PATH, b"{}"),        # 405
            ):
                _, _, payload = request(port, method, path, body=body)
                decoded = json.loads(payload)
                self.assertIn("detail", decoded)
                seen.add(decoded["error"])
        self.assertTrue(seen)
        for code in seen:
            self.assertIn(code, serve.ERROR_CODES)

    def test_the_two_versions_are_two_things(self):
        # `/v1/` versions the envelope; `skewline-fit/1` versions the
        # payload. An error response carries no payload tag at all, which
        # is why one cannot version the other.
        self.assertTrue(serve.MODEL_PATH.startswith(f"/{serve.API_VERSION}/"))
        with artifact_file() as missing, running(missing) as port:
            _, _, body = request(port, "GET", serve.MODEL_PATH)
        self.assertNotIn("schema", json.loads(body))


if __name__ == "__main__":
    unittest.main()
