"""The page the service renders, as one pure function.

A browser cannot import `fit.py` or `Sources/Model`, so a page that read
the artifact for itself would be a THIRD implementation of one schema --
after the Python that writes it and the Swift that reads it. This
repository refused the second one already: `serve.py` reads through
`fit.read_artifact` rather than a second parser of the same schema. So the
page is rendered here, in the same Python that owns the schema, and the
browser is handed a finished document. There is no reader in the browser,
no script, and nothing of ours for it to fetch.

What the viewer never gets is a depth of their own. Making the rendered
depths selectable needs either script -- the third evaluator, back again --
or a query parameter, which is the per-point query the wire refuses,
because "what is the disagreement at depth d" sends the CLIENT's depth up.
The page is therefore non-interactive on depth by construction, and every
depth on it is the repository's own.

The page evaluates, and only at depths this repository fixed: `DEPTH_LADDER`
is `fit.DEPTH_LADDER`, the same eight `ModelProbe` prints, so the two
readers can be compared as two outputs rather than trusted. Every estimate
goes through `fit.estimate` -- the refuser, never `fit.predict`, which is a
shared evaluator that answers wherever it is asked -- so a silence here is
the silence `Sources/Model` reports for the same class at the same depth.

Pure, and deliberately: `render` takes the artifact `fit.read_artifact`
already returned and the shell `serve.py` already read, and touches no file
and no request. That is `serve.py`'s own split -- a router with no socket in
it -- moved one seam further out.
"""

import html
import string

import fit

# --- Registered shape -------------------------------------------------------

# The three classes in `fit.CLASS_NAMES` order. A dictionary has no order and
# these panels are not going to inherit one -- the discipline ModelProbe
# already applies to its class blocks and its form names.
CLASS_ORDER = fit.CLASS_NAMES

# The registered ladder, imported rather than restated: `fit.py` is where it is
# declared and this is the mirror-free side of it -- Swift has to carry its own
# copy because it cannot read a Python constant, and a test pins that one.
DEPTH_LADDER = fit.DEPTH_LADDER

# The formula each named form is evaluated from, for a reader looking at its
# coefficients. A form this table cannot name is still rendered -- with its
# coefficients and without a formula -- because refusing an artifact belongs to
# `fit.read_artifact` and to the Swift reader, and a renderer that hid a form
# it could not name would be hiding what the artifact says.
FORMULAS = {
    "affine": "a + b·d",
    "quadratic": "a + b·d²",
    "power": "a·d^p",
}

# Anything absent reads as absent. A blank cell and a zero are both worse than
# a sentence, and this repository's whole thesis is that a silence has to be
# legible as one.
ABSENT = '<span class="none">not carried by the artifact</span>'


# --- The page ----------------------------------------------------------------

def render(artifact, shell):
    """The artifact as one HTML document.

    `artifact` is what `fit.read_artifact` returned; `shell` is the text of
    `view.html`, whose single `$content` placeholder this fills. Dollar
    substitution rather than `str.format`, because the shell is mostly CSS and
    every brace in it would otherwise need doubling; `substitute` rather than
    `safe_substitute`, so a mistyped placeholder is loud.
    """
    return string.Template(shell).substitute(content="\n".join(_content(artifact)))


def _content(artifact):
    yield "<h1>Skewline<span>the fitted model</span></h1>"
    yield ('<p class="tag">'
           + " · ".join([
               _text(artifact.get("schema", "")),
               _text(artifact.get("units", "")),
               "re-read per request",
           ])
           + "</p>")
    yield from _facts(artifact)
    yield ('<p class="note">Each class below is evaluated at one registered '
           "ladder of depths — the same eight the model probe prints, fixed in "
           "this repository and recorded in docs/DEVLOG.md, so the two readers "
           "can be compared as two outputs. None of them is a depth a viewer "
           "chose.</p>")

    classes = artifact.get("classes", {})
    for name in CLASS_ORDER:
        if name in classes:
            yield from _panel(name, classes[name])
        else:
            yield (f'<section class="cls absent"><h2>{_text(name)}</h2>'
                   f"<p class=\"why\">The artifact carries no {_text(name)} class.</p>"
                   "</section>")
    # A class this repository does not name still gets a panel. Dropping it
    # would be exactly the silent coercion the readers on both sides refuse.
    for name in sorted(set(classes) - set(CLASS_ORDER)):
        yield from _panel(name, classes[name])

    yield ('<p class="silence">Every estimate above is computed here, in the '
           "same Python that fitted the model, at depths fixed in this "
           "repository: there is no depth on this page a viewer chose. Making "
           "them selectable needs either a script in the browser — a third "
           "reader of one schema — or a query parameter, which would send the "
           "asker's own depth up the wire, and this service accepts "
           "neither.</p>")


def _facts(artifact):
    yield '<dl class="facts">'
    yield _fact("estimand", _text(artifact["estimand"]) if "estimand" in artifact else ABSENT)
    yield _fact("depth domain", _domain(artifact.get("depthDomain")))
    yield _fact("trained on", _provenance(artifact))
    yield "</dl>"


def _fact(label, value):
    return f"<dt>{_text(label)}</dt><dd>{value}</dd>"


def _domain(domain):
    """The domain, and the inclusivity the artifact does not settle.

    `depthDomain` is two bare numbers with no marker, so "does 5.0 m answer?"
    has no answer in `skewline-fit/1`. The Swift reader resolved it half-open
    on the banded table's own band arithmetic; this page reads it the same way
    rather than resolving it a second way and putting the two readers one depth
    apart.
    """
    if not isinstance(domain, list) or len(domain) != 2:
        return ABSENT
    low, high = domain
    return (f"{_bound(low)} ≤ d &lt; {_bound(high)} m"
            '<span class="note">The artifact carries two bare numbers and no '
            "inclusivity marker. Read half-open here, as the Swift reader reads "
            "it, so the upper bound refuses — for an adopted class exactly as "
            "for a refused one. Outside this range nothing answers at all: that "
            "silence belongs to the domain, not to any class.</span>")


def _provenance(artifact):
    sessions = artifact.get("trainedOn")
    if not isinstance(sessions, list):
        return ABSENT
    decimation = {
        entry.get("session"): entry.get("decimation")
        for entry in artifact.get("export", [])
        if isinstance(entry, dict)
    }
    rows = []
    for session in sessions:
        # A decimation is a count, not a measurement: it prints as the integer
        # the export wrote, never at a metric's six decimals.
        where = decimation.get(session)
        shown = _text(where) if isinstance(where, int) and not isinstance(where, bool) else ABSENT
        rows.append(f"<li>{_text(session)}<span>decimation {shown}</span></li>")
    return f"{len(sessions)} sessions<ul class=\"sessions\">{''.join(rows)}</ul>"


# --- One class ---------------------------------------------------------------

def _panel(name, model):
    verdict = model.get("verdict")
    css = verdict if verdict in ("adopted", "refused") else "unnamed"
    yield f'<section class="cls {css}">'
    yield (f"<h2>{_text(name)}"
           f'<span class="verdict">{_text(verdict) if verdict else "no verdict"}</span></h2>')
    if verdict == "adopted":
        yield from _adopted(model)
    elif verdict == "refused":
        yield from _refused(model)
    else:
        yield ('<p class="why">This class carries a verdict this page cannot '
               "name, so no form and no table are shown for it.</p>")
    # The class's answer, then the evidence for it: the ladder above the folds.
    yield from _ladder(model)
    yield from _folds(model.get("folds", []))
    yield "</section>"


def _adopted(model):
    form = model.get("form")
    formula = FORMULAS.get(form)
    named = _text(form) if form else ABSENT
    yield ('<p class="why">A continuous form beat the fold\'s own table in '
           f"every fold, so this class adopted <code>{named}</code>"
           + (f" — <code>{formula}</code>" if formula else "")
           + ", in meters of median pairwise disagreement.</p>")
    coefficients = model.get("coefficients", {})
    if not coefficients:
        yield f'<p class="coefficients">{ABSENT}</p>'
        return
    # Sorted, and every coefficient the artifact carries is shown: quietly
    # dropping one would be the same silent coercion the Swift reader refuses
    # an artifact over.
    shown = "".join(
        f"<span><b>{_text(key)}</b>{_number(value)}</span>"
        for key, value in sorted(coefficients.items())
    )
    yield f'<p class="coefficients">{shown}</p>'


def _refused(model):
    yield ('<p class="why">No candidate form beat the fold\'s own table in '
           "every fold, so this class adopted no continuous form and there are "
           "no coefficients to show. It keeps the banded table it came in with, "
           "and that table still answers.</p>")
    yield from _bands(model.get("table", {}))


def _bands(table):
    edges = table.get("edges", [])
    medians = table.get("medians", [])
    if not medians:
        yield f'<p class="why">{ABSENT}</p>'
        return
    yield '<table class="bands">'
    yield ("<tr><th>band (m)</th>"
           "<th>median pairwise disagreement (m)</th></tr>")
    for index, median in enumerate(medians):
        if index + 1 < len(edges):
            band = f"[{_bound(edges[index])}, {_bound(edges[index + 1])})"
        else:
            band = ABSENT
        if median is None:
            # A band nobody sampled has no median. Not zero, not blank: the
            # third silence, and it reads as itself.
            cell = '<span class="none">no samples</span>'
        else:
            cell = _number(median)
        yield f"<tr><th>{band}</th><td>{cell}</td></tr>"
    yield "</table>"


def _ladder(model):
    """The registered depths, answered through `fit.estimate`.

    Through the refuser and never through `fit.predict`: the parametric forms
    are evaluated wherever asked, so `predict` would put a number on this page
    at 6.0 m where the Swift reader refuses, and its table path returns one
    NaN for two silences that are not one thing.
    """
    rows = []
    for depth in DEPTH_LADDER:
        try:
            rows.append((depth, fit.estimate(model, depth)))
        except ValueError as refusal:
            # The refuser names four cases and no fifth. A class this page
            # cannot evaluate -- an unnamed verdict, a form the fit has no
            # arithmetic for, a table that does not span the domain -- gets a
            # sentence and never a number. Everything the artifact carries for
            # it is still above; what is refused is inventing an estimate.
            yield ('<p class="why">No ladder is evaluated for this class: '
                   f"{_text(refusal)}. What the artifact carries for it is "
                   "shown above, and an estimate that cannot be computed is "
                   "not invented here.</p>")
            return
    yield '<table class="ladder">'
    yield ("<tr><th>depth (m)</th>"
           "<th>median pairwise disagreement (m)</th></tr>")
    for depth, answer in rows:
        yield f"<tr><th>{_bound(depth)}</th><td>{_answer(answer)}</td></tr>"
    yield "</table>"


def _answer(answer):
    """One of `fit.estimate`'s four cases as a cell. A case this page cannot
    name reads as absent rather than as one of the refusals it is not."""
    case, meters = answer.get("case"), answer.get("meters")
    if case == fit.FROM_ADOPTED_FORM:
        return _number(meters)
    if case == fit.FROM_BANDED_TABLE:
        # The refused class answering, marked as ModelProbe marks it, because
        # "this number came from the table it kept" is the v0.6 finding.
        return f'{_number(meters)}<span class="margin">table</span>'
    if case == fit.REFUSED_BAND_WITHOUT_SAMPLES:
        return '<span class="none">refused: no samples in this band</span>'
    if case == fit.REFUSED_OUTSIDE_DEPTH_DOMAIN:
        # Named as the domain's refusal and not the class's: the sentence that
        # explains it sits above every class, because that silence belongs to
        # the domain rather than to any one of them.
        return '<span class="none">refused: outside the domain</span>'
    return ABSENT


def _holdout(name):
    """A session identifier shortened to its first UUID block, as DEVLOG writes
    them, so the widest column in the fold table is not the one carrying the
    least: full-width holdouts pushed the adopted form's margin -- the evidence
    this rung gave a sign on purpose -- off the card at the default width. The
    four full identifiers are on this page, in TRAINED ON.

    A name that is not UUID-shaped prints whole. Shortening an arbitrary one
    could make two rows read identically, and each row here is a different
    container's evidence.
    """
    text = str(name)
    blocks = text.split("-")
    shaped = ([len(block) for block in blocks] == [8, 4, 4, 4, 12]
              and all(digit in string.hexdigits for digit in text.replace("-", "")))
    return f"{_text(blocks[0])}…" if shaped else _text(text)


def _folds(folds):
    if not folds:
        return
    columns = sorted({
        name for fold in folds
        if isinstance(fold, dict)
        for name in fold.get("forms", {})
    })
    yield ('<p class="note">One row per leave-one-out fold: the metric that '
           "fold's own table scored on the held-out container, then each "
           "candidate's metric with its margin against that table. A positive "
           "margin beat the table on that fold, and adoption needs every "
           "fold — which is why a margin is printed with its sign.</p>")
    yield '<table class="folds">'
    yield ("<tr><th>holdout</th><th>table</th>"
           + "".join(f"<th>{_text(name)}</th>" for name in columns)
           + "</tr>")
    for fold in folds:
        cells = "".join(
            f"<td>{_outcome(fold.get('forms', {}).get(name))}</td>"
            for name in columns
        )
        yield (f"<tr><th>{_holdout(fold.get('holdout', ''))}</th>"
               f"<td>{_number(fold.get('table'))}</td>{cells}</tr>")
    yield "</table>"


def _outcome(entry):
    if not isinstance(entry, dict):
        return '<span class="none">not reported</span>'
    if entry.get("disqualified"):
        # Disqualified by the positivity gate before selection ever compared
        # it -- a different thing from losing, and it reads differently.
        return '<span class="none">disqualified</span>'
    margin = entry.get("margin")
    signed = _signed(margin) if isinstance(margin, (int, float)) else ABSENT
    return (f"{_number(entry.get('metric'))}"
            f'<span class="margin">{signed}</span>')


# --- Formatting ---------------------------------------------------------------

def _text(value):
    """Every artifact-derived string becomes markup through here.

    `html.escape` with `quote=True`, so a value is safe in an attribute as well
    as in a text node. Nothing a viewer supplies can reach this page -- there is
    no query surface at all -- so what this guards is a hostile artifact, which
    is the operator's own file. Cheap, and it is not a claim about untrusted
    input.
    """
    return html.escape(str(value), quote=True)


def _fixed(value):
    """Six decimals for a coefficient or a metric: `ModelProbe`'s `fixed`, so
    the two readers print the same number at the same width."""
    return f"{value:.6f}"


def _signed(value):
    """`ModelProbe`'s `signed`, and the reason it exists as a third format: a
    margin's SIGN is the finding. `0.000004` reads as a magnitude, while
    `+0.000004` beside `-0.000002` makes the flip across folds unmissable, and
    that flip is what the unanimity bar refuses to average away."""
    return f"{value:+.6f}"


def _bound(value):
    """Two decimals for a depth or a band edge: `ModelProbe`'s `bound`."""
    return f"{value:.2f}"


def _number(value):
    """A metric, a coefficient or a band median at six decimals; anything that
    is not a number reads as absent rather than as a crash or a zero."""
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        return ABSENT
    return _fixed(value)
