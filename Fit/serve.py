"""The local endpoint that serves what the fit produced, and the page that
reads it.

The wire runs one way. This service hands the `skewline-fit/1` artifact
down to a client and accepts nothing back: not a frame, not a depth map,
not an observation row, and not a per-point query -- a "what is sigma-hat
at depth d" endpoint would send the CLIENT's depths up, and the model is
public where the client's questions are not. So the whole artifact goes
down and the consumer evaluates locally. The DATA api is one GET, and it
is not a query surface.

The second route serves a page rather than data, and it is the first
consumer here that does NOT read the artifact for itself: the reading
happens in this process and the browser is handed a finished document. It
is safe for one precise reason, which is the reason worth stating rather
than the count of routes: no depth a client picked ever travels up. The page's
depths are the repository's, fixed in the tree, and there is no parameter
that could carry the viewer's instead. That is why the page is served off
`/` rather than under `/v1/`: an HTML document has no payload version, so
putting it under the prefix that versions the endpoint set and the error
shape would promise a stability nothing here enforces. The error shape is
already service-wide -- an unknown path has always answered in it -- while
`/v1/` stays a set of exactly one endpoint.

The refusal is enforced by the router rather than promised in prose: no
route reads a request body, and every method other than GET and HEAD is
answered 405 without one being read.

Where it binds is the operator's, and loopback is what they get for
saying nothing. v0.7 registered the loopback bind as a privacy decision
and shipped no flag at all; a phone cannot reach a loopback socket on a
laptop, so this rung adds `--host` rather than leaving the only client
that needs the endpoint unable to use it. The decision survives the
flag intact, because the flag does not move the default: binding where
a network can see it is now an explicit act with a warning attached,
and the value nobody names is still 127.0.0.1. Nothing about the wire
changes -- the same one GET goes down, the same nothing comes up -- so
what widens is reach, not what is exposed. There is no authentication
and that is still a finding rather than a shortcut: the artifact being
served is already in a public git repository, so a credential over it
would be theater.

The artifact is read through `fit.read_artifact`, never re-parsed here --
a second reader of the same schema is how two readers drift apart, and a
page that read it in the browser would be a THIRD, which is why the HTML
is rendered here instead. The import runs one way too: this module imports
`fit` and `view`, and neither learns anything about serving, the same
shape as Replay never depending on Capture.

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
import os
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

import fit
import view

# --- Registered constants -------------------------------------------------

API_VERSION = "v1"
MODEL_PATH = f"/{API_VERSION}/model"

# Off the version prefix, and at the root because that is what a person
# types. `/v1/` versions the endpoint set and the error shape; an HTML
# document has no payload version to promise, and keeping it out of the
# prefix leaves the data api exactly one GET.
VIEW_PATH = "/"

# The page's shell, beside this module. Read per request, exactly as the
# artifact is and for the same reason: edit it and reload, no restart. The
# cost is a second file read per request, which nobody has measured; it is
# not a caching decision.
VIEW_DOCUMENT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "view.html")

# The default, and the only value that needs no argument. That default is a
# privacy decision, not a convenience: a service reachable from the network
# is something an operator asks for by naming an interface, never something
# this file picks on their behalf. `--host` is that ask, and it is `--port`'s
# shape -- a flag whose absence leaves the safe value in place.
BIND_HOST = "127.0.0.1"

# Ephemeral, and the bound port is printed. The repository commits no
# invented port number, and the operator's path is the tests' path.
DEFAULT_PORT = 0

# Addresses that mean "every interface" rather than naming one. They bind
# fine and they are useless in a URL: a client cannot connect to 0.0.0.0, so
# the startup line has to say so rather than print it and look helpful. No
# address is discovered to fill the gap -- choosing an interface for the
# operator is the default this flag exists to avoid.
WILDCARD_HOSTS = ("0.0.0.0", "::", "")

# RFC 9110 section 9.1: a general-purpose server MUST support GET and HEAD;
# every other method is OPTIONAL. HEAD is answered rather than refused on
# this rung's own terms as well -- the refusal is about methods that carry
# a body, and HEAD carries none.
ALLOWED_METHODS = ("GET", "HEAD")

# Per route, and carried by the resolved response rather than branched on
# in the send path. JSON keeps no charset parameter -- RFC 8259 fixes it as
# UTF-8 -- while HTML needs one, and carries the meta tag as well.
CONTENT_TYPE_JSON = "application/json"
CONTENT_TYPE_HTML = "text/html; charset=utf-8"

NO_MODEL = "no-model"
BAD_ARTIFACT = "bad-artifact"
METHOD_NOT_ALLOWED = "method-not-allowed"
NO_SUCH_ENDPOINT = "no-such-endpoint"
# The page's shell is committed to the repository, so its absence is a broken
# checkout rather than a state this service passes through -- which is why it
# is a 500 beside `bad-artifact` and not a 503 beside `no-model`. Its own code,
# because a missing document and a corrupt artifact are different findings.
NO_VIEW = "no-view"

ERROR_CODES = (NO_MODEL, BAD_ARTIFACT, METHOD_NOT_ALLOWED, NO_SUCH_ENDPOINT,
               NO_VIEW)


# --- The response bodies ----------------------------------------------------

def encode(payload):
    """The artifact's own serialization: `fit.write_artifact` writes
    `indent=2, sort_keys=True` and a trailing newline, so a 200 reproduces
    the bytes that writer writes. The scope is exactly that -- an artifact
    edited by hand is served NORMALIZED, not byte-for-byte as it sits on
    disk."""
    return (json.dumps(payload, indent=2, sort_keys=True) + "\n").encode("utf-8")


def _error(status, code, detail, headers=()):
    return status, CONTENT_TYPE_JSON, list(headers), encode(
        {"error": code, "detail": detail}
    )


def _artifact_or_error(artifact_path):
    """The artifact, or the response refusing it, as `(artifact, error)`.

    Both routes read it and both refuse it identically -- a page has no better
    answer to a missing fit than the endpoint does, and writing the refusal
    twice is how the two would come to differ. The artifact is re-read per
    request, so a fit that lands while the service runs is served without a
    restart. The cost is a file read per request, which nobody has measured;
    it is not a caching decision.
    """
    try:
        return fit.read_artifact(artifact_path), None
    except FileNotFoundError:
        return None, _error(
            503, NO_MODEL,
            f"no artifact at {artifact_path} yet; run Fit/fit.py to produce one",
        )
    except (ValueError, OSError) as problem:
        # Refused at read rather than proxied: a foreign or corrupt file is
        # the operator's, not the request's, and never reaches a client.
        return None, _error(500, BAD_ARTIFACT, f"{artifact_path}: {problem}")


def model_response(artifact_path):
    """GET /v1/model. The artifact, as the bytes `write_artifact` wrote."""
    artifact, error = _artifact_or_error(artifact_path)
    if error is not None:
        return error
    return 200, CONTENT_TYPE_JSON, [], encode(artifact)


def view_response(artifact_path, view_path):
    """GET /. The same artifact, rendered here rather than in the browser.

    Errors stay in the `/v1/` JSON shape on this route too. One service, one
    error shape: an HTML error page would fork the envelope for cosmetics, and
    `ERROR_CODES` would stop meaning one thing. A browser meeting a 503 sees
    the same body a client would.
    """
    artifact, error = _artifact_or_error(artifact_path)
    if error is not None:
        return error
    try:
        with open(view_path, encoding="utf-8") as handle:
            shell = handle.read()
    except OSError as problem:
        return _error(500, NO_VIEW, f"{view_path}: {problem}")
    return 200, CONTENT_TYPE_HTML, [], view.render(artifact, shell).encode("utf-8")


def resolve(method, path, artifact_path, view_path=VIEW_DOCUMENT):
    """The whole router, as one function with no socket in it.

    Returns `(status, content_type, extra_headers, body)` -- the content type
    rides the resolved response rather than being branched on where the bytes
    go out, because two routes now disagree about it and the send path should
    not have to know which.

    Path matching is exact on both routes, which is what makes "not a query
    surface" mechanically true: `/v1/model` with a query string is not the
    endpoint, and `/?depth=2.0` is not the page.
    """
    if path not in (MODEL_PATH, VIEW_PATH):
        return _error(
            404, NO_SUCH_ENDPOINT,
            f"no endpoint at {path}; this service serves {VIEW_PATH} and "
            f"{MODEL_PATH}, and takes no query parameters",
        )
    if method not in ALLOWED_METHODS:
        return _error(
            405, METHOD_NOT_ALLOWED,
            f"{method} is not allowed on {path}; this service serves a model "
            f"and a page describing it, and accepts no upload",
            headers=[("Allow", ", ".join(ALLOWED_METHODS)),
                     ("Connection", "close")],
        )
    if path == MODEL_PATH:
        return model_response(artifact_path)
    return view_response(artifact_path, view_path)


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

    def _resolve(self, method):
        return resolve(
            method, self.path, self.server.artifact_path, self.server.view_path
        )

    def do_GET(self):
        self._respond(*self._resolve("GET"))

    def do_HEAD(self):
        # GET's status line and headers, including the Content-Length GET
        # would have sent, with an empty body.
        self._respond(*self._resolve("HEAD"), send_body=False)

    def _refuse(self):
        self._respond(*self._resolve(self.command))

    do_POST = _refuse
    do_PUT = _refuse
    do_PATCH = _refuse
    do_DELETE = _refuse
    do_OPTIONS = _refuse

    def _respond(self, status, content_type, headers, body, send_body=True):
        self.send_response(status)
        self.send_header("Content-Type", content_type)
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

    def __init__(self, address, artifact_path, log_requests=True,
                 view_path=VIEW_DOCUMENT):
        self.artifact_path = artifact_path
        self.view_path = view_path
        self.log_requests = log_requests
        super().__init__(address, ArtifactHandler)


# --- The driver ---------------------------------------------------------------

def _authority(host, port):
    """`host:port` for a URL, bracketing an IPv6 literal -- RFC 3986 section
    3.2.2, because `http://::1:8000/` parses as neither one."""
    return f"[{host}]:{port}" if ":" in host else f"{host}:{port}"


def startup_report(host, port, artifact_path):
    """What a run says on the way up, as `(stdout, stderr)` line lists.

    A pure function with no socket in it, the same split `resolve` makes and
    for the same reason: what a non-loopback bind tells the operator is a
    decision, and the tests should be able to drive it without binding
    anything anywhere.
    """
    url = f"http://{_authority(host, port)}"
    out = [
        f"serving {fit.ARTIFACT_SCHEMA} from {artifact_path} at {url}{MODEL_PATH}",
        f"the page that reads it: {url}{VIEW_PATH}",
    ]
    err = []
    if host != BIND_HOST:
        # Said every run, not once at the flag: the reach is a property of
        # this process while it lives, and the operator is the only one who
        # can end it.
        err.append(
            f"warning: bound to {host!r}, not loopback. Anyone who can reach "
            "this machine on that network can read the model and the page, "
            "with no credential, for as long as this runs. That is acceptable "
            "because nothing served is private -- the artifact is already in a "
            "public repository -- and because nothing goes up: there is no "
            "upload endpoint and no query surface. One line per request goes "
            "to stderr, carrying the client's address and a timestamp."
        )
    if host in WILDCARD_HOSTS:
        err.append(
            f"warning: {host!r} is every interface, not an address a client "
            "can use. The URL above is not one you can type into a phone -- "
            "pass --host <this machine's address on that network> to print "
            "one that is."
        )
    return out, err


def parse_bind(arguments):
    """`(host, port)` from whatever follows the artifact path.

    Pure, so the privacy default is testable by driving the parse rather
    than by reading the source: no argument list that omits `--host` can
    return anything but `BIND_HOST`, and a test says so. Raises
    `ValueError` for an argument this driver does not know.
    """
    host = BIND_HOST
    port = DEFAULT_PORT
    rest = list(arguments)
    while rest:
        if rest[0] == "--port" and len(rest) >= 2:
            port = int(rest[1])
            rest = rest[2:]
            continue
        if rest[0] == "--host" and len(rest) >= 2:
            host = rest[1]
            rest = rest[2:]
            continue
        raise ValueError(f"unknown argument {rest[0]!r}")
    return host, port


def main(argv):
    if len(argv) < 2:
        print("usage: serve.py <artifact.json> [--port N] [--host ADDRESS]")
        return 64
    artifact_path = argv[1]
    try:
        host, port = parse_bind(argv[2:])
    except ValueError as problem:
        print(f"serve.py: {problem}")
        return 64

    try:
        server = ModelServer((host, port), artifact_path)
    except OSError as problem:
        # The likeliest operator error this flag introduces is an address
        # that is not on this machine, and a traceback is a poor answer to
        # a typo. Same exit as the argument loop's: both are fixed by
        # running the command again differently.
        print(f"serve.py: cannot bind {host!r}:{port}: {problem}",
              file=sys.stderr)
        return 64
    bound = server.server_address[1]
    out, err = startup_report(host, bound, artifact_path)
    # Flushed: with the port ephemeral by default, these lines are how the
    # caller learns where to connect, and stdout is block-buffered the
    # moment it is a pipe rather than a terminal.
    for line in out:
        print(line, flush=True)
    for line in err:
        print(line, file=sys.stderr, flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
