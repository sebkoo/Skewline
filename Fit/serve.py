"""The local endpoint that serves what the fit produced.

The wire runs one way. This service hands the `skewline-fit/1` artifact
down to a client and accepts nothing back: not a frame, not a depth map,
not an observation row, and not a per-point query -- a "what is sigma-hat
at depth d" endpoint would send the CLIENT's depths up, and the model is
public where the client's questions are not. So the whole artifact goes
down and the consumer evaluates locally. That is why the API is one GET
rather than a query surface.

The refusal is enforced by the router rather than promised in prose: no
route reads a request body, and every method other than GET and HEAD is
answered 405 without one being read.

The artifact is read through `fit.read_artifact`, never re-parsed here --
a second reader of the same schema is how two readers drift apart. The
import runs one way too: this module imports `fit`, and `fit` learns
nothing about serving, the same shape as Replay never depending on
Capture.

No dependency is added. numpy arrives transitively through `fit`, which is
the point; the serving itself is stdlib. If serving ever needs a
third-party dependency, that is the registered moment to move to its own
directory with its own requirements file, in the commit that introduces
it -- `Fit/requirements.txt` is the fit harness's pin file, and the
numerical tests must not start dragging a web framework along.

Two versions, of two different things: `skewline-fit/1` is a schema tag on
the payload; `/v1/` versions the endpoint set and the error shape. They
cannot be one thing, because an error response carries no payload tag at
all -- a 503 body has no `schema` field to read -- so something has to
version the envelope, and one path segment is the cheapest thing that can.
A consumer reads both, and the 200 body always carries its own tag so the
payload version is never inferred from the path.
"""

import json
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

import fit

# --- Registered constants -------------------------------------------------

API_VERSION = "v1"
MODEL_PATH = f"/{API_VERSION}/model"

# Loopback, and no flag exists to change it. That default is a privacy
# decision, not a convenience.
BIND_HOST = "127.0.0.1"

# Ephemeral, and the bound port is printed. The repository commits no
# invented port number, and the operator's path is the tests' path.
DEFAULT_PORT = 0

# RFC 9110 section 9.1: a general-purpose server MUST support GET and HEAD;
# every other method is OPTIONAL. HEAD is answered rather than refused on
# this rung's own terms as well -- the refusal is about methods that carry
# a body, and HEAD carries none.
ALLOWED_METHODS = ("GET", "HEAD")

CONTENT_TYPE = "application/json"

NO_MODEL = "no-model"
BAD_ARTIFACT = "bad-artifact"
METHOD_NOT_ALLOWED = "method-not-allowed"
NO_SUCH_ENDPOINT = "no-such-endpoint"

ERROR_CODES = (NO_MODEL, BAD_ARTIFACT, METHOD_NOT_ALLOWED, NO_SUCH_ENDPOINT)


# --- The response bodies ----------------------------------------------------

def encode(payload):
    """The artifact's own serialization: `fit.write_artifact` writes
    `indent=2, sort_keys=True` and a trailing newline, so a 200 reproduces
    the bytes that writer writes. The scope is exactly that -- an artifact
    edited by hand is served NORMALIZED, not byte-for-byte as it sits on
    disk."""
    return (json.dumps(payload, indent=2, sort_keys=True) + "\n").encode("utf-8")


def _error(status, code, detail, headers=()):
    return status, list(headers), encode({"error": code, "detail": detail})


def model_response(artifact_path):
    """GET /v1/model. The artifact is re-read per request, so a fit that
    lands while the service runs is served without a restart. The cost is a
    file read per request, which nobody has measured; it is not a caching
    decision."""
    try:
        artifact = fit.read_artifact(artifact_path)
    except FileNotFoundError:
        return _error(
            503, NO_MODEL,
            f"no artifact at {artifact_path} yet; run Fit/fit.py to produce one",
        )
    except (ValueError, OSError) as problem:
        # Refused at read rather than proxied: a foreign or corrupt file is
        # the operator's, not the request's, and never reaches a client.
        return _error(500, BAD_ARTIFACT, f"{artifact_path}: {problem}")
    return 200, [], encode(artifact)


def resolve(method, path, artifact_path):
    """The whole router, as one function with no socket in it.

    Returns `(status, extra_headers, body)`. Path matching is exact, which
    is what makes "not a query surface" mechanically true: `/v1/model` with
    a query string is not this endpoint.
    """
    if path != MODEL_PATH:
        return _error(
            404, NO_SUCH_ENDPOINT,
            f"no endpoint at {path}; this service serves {MODEL_PATH} "
            f"and takes no query parameters",
        )
    if method not in ALLOWED_METHODS:
        return _error(
            405, METHOD_NOT_ALLOWED,
            f"{method} is not allowed on {MODEL_PATH}; this service serves "
            f"a model and accepts no upload",
            headers=[("Allow", ", ".join(ALLOWED_METHODS)),
                     ("Connection", "close")],
        )
    return model_response(artifact_path)


# --- The handler --------------------------------------------------------------

class ArtifactHandler(BaseHTTPRequestHandler):
    """Serves `resolve`. Nothing here touches the request body -- the
    absence is the decision, and a client that sends one large enough to
    outrun the socket buffer may see the connection reset instead of the
    405, because the response closes with those bytes still in flight."""

    # No interpreter version is advertised; the default banner would carry
    # one, and nothing needs it. `version_string` is overridden rather than
    # just blanking `sys_version`, because the base class joins the two on a
    # space unconditionally and would leave a trailing one on the wire.
    server_version = "Skewline"
    sys_version = ""

    def version_string(self):
        return self.server_version

    def do_GET(self):
        self._respond(*resolve("GET", self.path, self.server.artifact_path))

    def do_HEAD(self):
        # GET's status line and headers, including the Content-Length GET
        # would have sent, with an empty body.
        self._respond(
            *resolve("HEAD", self.path, self.server.artifact_path),
            send_body=False,
        )

    def _refuse(self):
        self._respond(*resolve(self.command, self.path, self.server.artifact_path))

    do_POST = _refuse
    do_PUT = _refuse
    do_PATCH = _refuse
    do_DELETE = _refuse
    do_OPTIONS = _refuse

    def _respond(self, status, headers, body, send_body=True):
        self.send_response(status)
        self.send_header("Content-Type", CONTENT_TYPE)
        self.send_header("Content-Length", str(len(body)))
        for name, value in headers:
            self.send_header(name, value)
        self.end_headers()
        if send_body:
            self.wfile.write(body)

    def log_message(self, format, *args):
        # One line per request, to stderr, and no log file. A real
        # deployment's request log would carry client address, user agent
        # and timestamps -- that is a deployment-time question, recorded
        # rather than registered away.
        if self.server.log_requests:
            super().log_message(format, *args)


class ModelServer(ThreadingHTTPServer):
    daemon_threads = True

    def __init__(self, address, artifact_path, log_requests=True):
        self.artifact_path = artifact_path
        self.log_requests = log_requests
        super().__init__(address, ArtifactHandler)


# --- The driver ---------------------------------------------------------------

def main(argv):
    if len(argv) < 2:
        print("usage: serve.py <artifact.json> [--port N]")
        return 64
    artifact_path = argv[1]
    port = DEFAULT_PORT
    rest = argv[2:]
    while rest:
        if rest[0] == "--port" and len(rest) >= 2:
            port = int(rest[1])
            rest = rest[2:]
            continue
        print(f"serve.py: unknown argument {rest[0]!r}")
        return 64

    server = ModelServer((BIND_HOST, port), artifact_path)
    bound = server.server_address[1]
    # Flushed: with the port ephemeral by default, this line is how the
    # caller learns where to connect, and stdout is block-buffered the
    # moment it is a pipe rather than a terminal.
    print(f"serving {fit.ARTIFACT_SCHEMA} from {artifact_path} "
          f"at http://{BIND_HOST}:{bound}{MODEL_PATH}", flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()
    return 0


if __name__ == "__main__":
    import sys

    sys.exit(main(sys.argv))
