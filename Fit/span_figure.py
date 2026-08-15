"""The span result, drawn from the committed artifacts and nothing else.

This module reads `*.span.json` and writes SVG. It computes no statistic: every
number it draws is already in an artifact, put there by `span.py`, and a figure
that recomputed anything would be a second implementation of the estimand with
no test holding it to the first.

DETERMINISTIC BYTES, WHICH IS WHY THERE IS A TEST AT ALL.

An image is the one artifact nobody diffs. A hand-touched SVG, or one redrawn
by a later version of this file, would sit in the README claiming to be the
measurement while saying something else, and no reader would catch it. So the
output is byte-deterministic -- inputs sorted by session, one float-formatting
rule, no timestamps, no dictionary-order dependence -- and `test_span_figure`
regenerates both files and asserts equality with what is committed. Editing the
SVG by hand turns CI red, which is the only guard an image can have here.

STANDARD LIBRARY ONLY, DELIBERATELY.

`Fit/requirements.txt` pins `numpy` because the analysis needs it. This module
does arithmetic a pocket calculator would do, so it imports nothing, and
`requirements.txt` is not touched: a figure is not a reason to widen the
environment the gate runs in, and every dependency added for a nicety is one
the four other Python files inherit forever.

THE PALETTE IS NOT A PREFERENCE.

Colour carries the confidence class -- the entity, never its rank -- and the
three steps were checked rather than chosen by eye: each mode's palette clears
a lightness band, a chroma floor, an adjacent-pair separation under simulated
deuteranopia and tritanopia, a normal-vision floor and 3:1 contrast against
that mode's own surface. Dark is a separate set of steps validated against the
dark surface, not the light set inverted. The four containers inside one class
share its colour because they are replicates of each other and not four
identities; what distinguishes them is that there are four lines, which is the
claim the figure is making.
"""

import json
import os
import sys

# The tag this module will draw and no other. Duplicated from `span.py` rather
# than imported, because importing it would pull `numpy` into a module whose
# whole argument is that it needs nothing; `test_span_figure` pins the two
# constants equal, so the duplication cannot drift silently.
ARTIFACT_SCHEMA = "skewline-span/1"

# The categorical order, fixed. Never cycled, never sorted by value: colour
# follows the class, so a class keeps its colour whatever the numbers do.
CLASS_ORDER = ("low", "medium", "high")

USAGE = "usage: span_figure.py --artifacts <dir> --output-dir <dir>"

# Canvas. Chosen once so the committed bytes are stable; changing any of these
# changes both SVGs and the test says so.
WIDTH = 960
HEIGHT = 556
LEFT = 88
RIGHT = 772
TOP = 104
BOTTOM = 448
Y_MAX = 1.06

THEMES = {
    "light": {
        "surface": "#fcfcfb",
        "ink": "#1a1a19",
        "muted": "#6b6862",
        "grid": "#e6e4df",
        "rule": "#b9b5ad",
        "series": {"low": "#BE3126", "medium": "#BC8A10", "high": "#6094D8"},
    },
    "dark": {
        "surface": "#1a1a19",
        "ink": "#ececea",
        "muted": "#a09c94",
        "grid": "#322f2b",
        "rule": "#55524c",
        "series": {"low": "#BE3126", "medium": "#AA941C", "high": "#6094D8"},
    },
}


def num(value):
    """One formatting rule for every coordinate in the file.

    Two decimals, then trailing zeros and a trailing point removed, so `12.0`
    and `12.00` and `12` can never appear in three different runs for the same
    quantity. Determinism is the whole point: without a single rule the bytes
    depend on which branch computed the number.
    """
    text = "%.2f" % value
    if "." in text:
        text = text.rstrip("0").rstrip(".")
    return "0" if text in ("", "-0") else text


def escape(text):
    """The five XML predefined entities. Nothing here interpolates untrusted
    input -- the strings are class names and band edges -- but a session id
    would reach the file through a title one day, and an unescaped `&` is a
    broken document rather than a wrong one."""
    return (
        text.replace("&", "&amp;")
        .replace("<", "&lt;")
        .replace(">", "&gt;")
        .replace('"', "&quot;")
        .replace("'", "&apos;")
    )


def load_artifacts(directory):
    """Every `*.span.json` in one directory, sorted by session.

    Sorted, and not in `os.listdir` order: the filesystem's order is not a
    property of the measurement, and letting it into the output would make the
    committed bytes depend on which machine drew them. Anything that is not
    `skewline-span/1` is refused rather than skipped -- a directory holding a
    file this module cannot read is a state worth stopping on, since the
    likeliest cause is a schema that moved.
    """
    names = sorted(n for n in os.listdir(directory) if n.endswith(".span.json"))
    if not names:
        raise ValueError(f"{directory}: no *.span.json artifacts to draw")
    artifacts = []
    for name in names:
        path = os.path.join(directory, name)
        with open(path, encoding="utf-8") as handle:
            artifact = json.load(handle)
        schema = artifact.get("schema")
        if schema != ARTIFACT_SCHEMA:
            raise ValueError(
                f"{path}: schema is {schema!r}, not {ARTIFACT_SCHEMA!r}"
            )
        artifacts.append(artifact)
    artifacts.sort(key=lambda a: a["measuredOn"][0])
    return artifacts


def band_edges(artifacts):
    """The separation edges, required identical across every artifact.

    A figure whose x axis came from the first file it happened to read would
    silently mis-plot the rest. `span.py` writes the registered edges into
    every artifact precisely so this can be checked instead of assumed.
    """
    edges = artifacts[0]["separationEdges"]
    for artifact in artifacts[1:]:
        if artifact["separationEdges"] != edges:
            raise ValueError(
                "artifacts disagree on separationEdges, so one x axis cannot "
                "carry them"
            )
    return edges


def series(artifacts):
    """One entry per container and class: the ratios in band order.

    Cells are sorted by their low edge rather than trusted to arrive in it,
    because band order is what the whole figure asserts and reading it off the
    file's ordering would make the claim circular.
    """
    out = []
    for artifact in artifacts:
        session = artifact["measuredOn"][0]
        for name in CLASS_ORDER:
            cells = sorted(
                artifact["classes"][name]["axial"]["cells"],
                key=lambda c: c["low"],
            )
            out.append(
                {
                    "session": session,
                    "class": name,
                    "ratios": [c["ratio"] for c in cells],
                }
            )
    return out


def x_at(index, count):
    return LEFT + (RIGHT - LEFT) * index / (count - 1)


def y_at(ratio):
    return BOTTOM - (BOTTOM - TOP) * (ratio / Y_MAX)


def band_label(low, high):
    """`0.80–1.60`, and `0` rather than `0.00` at the origin. Half-open on both
    ends, the convention the bands themselves use."""
    left = "0" if low == 0 else ("%.2f" % low)
    return f"{left}–{'%.2f' % high}"


def _direct_labels(rows, count):
    """Where the three class labels sit at the right edge.

    Anchored to the topmost line of each class at the last band, then pushed
    apart to a minimum gap. Pushing is deterministic -- the order is
    `CLASS_ORDER` and the step is fixed -- so two runs place them identically.
    """
    anchors = []
    for name in CLASS_ORDER:
        tops = [r["ratios"][count - 1] for r in rows if r["class"] == name]
        anchors.append([name, y_at(max(tops))])
    anchors.sort(key=lambda a: a[1])
    for i in range(1, len(anchors)):
        if anchors[i][1] - anchors[i - 1][1] < 16:
            anchors[i][1] = anchors[i - 1][1] + 16
    return anchors


def build_svg(artifacts, theme_name):
    """The whole document, as one string."""
    theme = THEMES[theme_name]
    edges = band_edges(artifacts)
    count = len(edges) - 1
    rows = series(artifacts)
    parts = []
    add = parts.append

    add(
        f'<svg xmlns="http://www.w3.org/2000/svg" width="{WIDTH}" '
        f'height="{HEIGHT}" viewBox="0 0 {WIDTH} {HEIGHT}" '
        f'font-family="-apple-system, BlinkMacSystemFont, Segoe UI, Helvetica, '
        f'Arial, sans-serif" role="img" aria-label="Ratio of same-frame-pair '
        f"disagreement to a frame-disjoint null, rising with separation in all "
        f'twelve series">'
    )
    add(f'<rect width="{WIDTH}" height="{HEIGHT}" fill="{theme["surface"]}"/>')

    # Title block.
    add(
        f'<text x="{LEFT}" y="44" fill="{theme["ink"]}" font-size="20" '
        f'font-weight="600">Do two points’ errors cancel?</text>'
    )
    add(
        f'<text x="{LEFT}" y="68" fill="{theme["muted"]}" font-size="12.5">'
        f"Same-frame-pair disagreement over a depth-matched, frame-disjoint "
        f"null · 4 containers × 3 confidence classes × 7 bands"
        f"</text>"
    )

    # Horizontal grid, recessive, at the labelled ticks only.
    for tick in (0.0, 0.2, 0.4, 0.6, 0.8):
        y = y_at(tick)
        add(
            f'<line x1="{LEFT}" y1="{num(y)}" x2="{RIGHT}" y2="{num(y)}" '
            f'stroke="{theme["grid"]}" stroke-width="1"/>'
        )
        add(
            f'<text x="{LEFT - 12}" y="{num(y + 4)}" fill="{theme["muted"]}" '
            f'font-size="11.5" text-anchor="end">{"%.1f" % tick}</text>'
        )

    # The two registered boundaries. These are not grid lines and do not look
    # like them: 1.00 is what independence would read, and 0.90 is the boundary a
    # verdict needs to clear, both fixed before any container was exported.
    for value, label in ((0.9, "0.90  cancellation boundary"), (1.0, "1.00  independence")):
        y = y_at(value)
        add(
            f'<line x1="{LEFT}" y1="{num(y)}" x2="{RIGHT}" y2="{num(y)}" '
            f'stroke="{theme["rule"]}" stroke-width="1" '
            f'stroke-dasharray="5 4"/>'
        )
        add(
            f'<text x="{LEFT + 6}" y="{num(y - 6)}" fill="{theme["muted"]}" '
            f'font-size="11.5">{escape(label)}</text>'
        )

    # X axis: one tick per band, labelled with the band itself.
    add(
        f'<line x1="{LEFT}" y1="{num(y_at(0))}" x2="{RIGHT}" '
        f'y2="{num(y_at(0))}" stroke="{theme["rule"]}" stroke-width="1"/>'
    )
    for i in range(count):
        x = x_at(i, count)
        add(
            f'<text x="{num(x)}" y="{num(y_at(0) + 20)}" '
            f'fill="{theme["muted"]}" font-size="11" text-anchor="middle">'
            f"{escape(band_label(edges[i], edges[i + 1]))}</text>"
        )
    add(
        f'<text x="{num((LEFT + RIGHT) / 2)}" y="{num(y_at(0) + 44)}" '
        f'fill="{theme["muted"]}" font-size="12" text-anchor="middle">'
        f"lateral separation between the two points (m)</text>"
    )
    add(
        f'<text transform="translate(28 {num((TOP + BOTTOM) / 2)}) rotate(-90)" '
        f'fill="{theme["muted"]}" font-size="12" text-anchor="middle">'
        f"ratio (below 1 is cancellation)</text>"
    )

    # The twelve series. Lines first, then markers, so no marker is buried
    # under a line drawn after it.
    for row in rows:
        color = theme["series"][row["class"]]
        points = " ".join(
            f"{num(x_at(i, count))},{num(y_at(r))}"
            for i, r in enumerate(row["ratios"])
        )
        add(
            f'<polyline points="{points}" fill="none" stroke="{color}" '
            f'stroke-width="2" stroke-linejoin="round" stroke-linecap="round"/>'
        )
    for row in rows:
        color = theme["series"][row["class"]]
        for i, r in enumerate(row["ratios"]):
            add(
                f'<circle cx="{num(x_at(i, count))}" cy="{num(y_at(r))}" '
                f'r="3.6" fill="{color}" stroke="{theme["surface"]}" '
                f'stroke-width="1.4"/>'
            )

    # The one cell above 1, found rather than hardcoded. Anti-correlation is
    # the outcome `span.py` calls out as its own finding, so a figure that let
    # it disappear into the crowd would be arguing against the module.
    above = [
        (i, r["ratios"][i])
        for r in rows
        for i in range(count)
        if r["ratios"][i] is not None and r["ratios"][i] > 1.0
    ]
    if len(above) == 1:
        i, value = above[0]
        x, y = x_at(i, count), y_at(value)
        add(
            f'<circle cx="{num(x)}" cy="{num(y)}" r="9" fill="none" '
            f'stroke="{theme["ink"]}" stroke-width="1.2"/>'
        )
        add(
            f'<text x="{num(x - 16)}" y="{num(y - 14)}" fill="{theme["ink"]}" '
            f'font-size="11.5" text-anchor="end">one cell above 1 — '
            f"unsettled by seed</text>"
        )

    # Direct labels at the right edge, in ink rather than in the series colour:
    # a coloured dot beside the word carries the identity, and the word itself
    # stays readable to anyone the colour fails.
    for name, y in _direct_labels(rows, count):
        color = theme["series"][name]
        add(
            f'<circle cx="{RIGHT + 16}" cy="{num(y)}" r="4" fill="{color}"/>'
        )
        add(
            f'<text x="{RIGHT + 26}" y="{num(y + 4)}" fill="{theme["ink"]}" '
            f'font-size="12">{escape(name)}</text>'
        )

    # Legend. Present because identity must never be colour alone, and it says
    # what a single line is -- without that sentence, twelve lines in three
    # colours look like three series drawn badly.
    add(
        f'<text x="{LEFT}" y="{HEIGHT - 30}" fill="{theme["muted"]}" '
        f'font-size="11.5">One line per container, four per class; colour is '
        f"the sensor’s own confidence class.</text>"
    )
    add(
        f'<text x="{LEFT}" y="{HEIGHT - 13}" fill="{theme["muted"]}" '
        f'font-size="11.5">Every point is an upper median over thousands of '
        f"pairs, never a per-row value.</text>"
    )

    add("</svg>")
    return "\n".join(parts) + "\n"


def write_figures(artifacts, output_dir):
    """Both themes, one file each. Returns the paths written, sorted."""
    written = []
    for theme_name in sorted(THEMES):
        path = os.path.join(output_dir, f"span-{theme_name}.svg")
        with open(path, "w", encoding="utf-8", newline="\n") as handle:
            handle.write(build_svg(artifacts, theme_name))
        written.append(path)
    return written


def main(argv):
    artifacts_dir = None
    output_dir = None
    rest = list(argv)
    while rest:
        token = rest.pop(0)
        if token == "--artifacts" and rest:
            artifacts_dir = rest.pop(0)
        elif token == "--output-dir" and rest:
            output_dir = rest.pop(0)
        else:
            print(USAGE, file=sys.stderr)
            return 64
    if artifacts_dir is None or output_dir is None:
        print(USAGE, file=sys.stderr)
        return 64
    try:
        artifacts = load_artifacts(artifacts_dir)
        written = write_figures(artifacts, output_dir)
    except (OSError, ValueError, KeyError) as error:
        print(f"span_figure.py: {error}", file=sys.stderr)
        return 1
    for path in written:
        print(f"wrote {path}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
