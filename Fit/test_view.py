"""Tests for the page the service renders.

The renderer is a pure function of the artifact and the shell, so these
drive it directly -- no socket, no server, no port. The route's own
behavior is `test_serve.py`'s; what is checked here is what a reader sees,
and above all that a refusal reads as a refusal.

The real `Fit/view.html` is used rather than a stub, because two of the
claims -- no script, nothing fetched -- are claims about the whole
document, and a stub shell would exempt the half that is hand-written.
"""

import html
import inspect
import json
import os
import unittest

import fit
import view

HERE = os.path.dirname(os.path.abspath(__file__))
COMMITTED_ARTIFACT = os.path.join(HERE, "model.json")
SHELL = os.path.join(HERE, "view.html")


def shell():
    with open(SHELL, encoding="utf-8") as handle:
        return handle.read()


def render(artifact):
    return view.render(artifact, shell())


def committed():
    return render(fit.read_artifact(COMMITTED_ARTIFACT))


def section(page, name):
    """The one class panel, sliced out by its heading, so an assertion about
    what the high class does NOT show cannot be satisfied by the low class
    across the page."""
    for chunk in page.split("<section"):
        if f">{name}<" in chunk.split("</h2>")[0]:
            return chunk
    raise AssertionError(f"no panel for {name}")


def planted(**overrides):
    """A small `skewline-fit/1` carrying three shapes the committed artifact
    does not: a band with no samples, a form this page cannot name, and a
    string with markup in it."""
    artifact = {
        "schema": fit.ARTIFACT_SCHEMA,
        "estimand": fit.ESTIMAND,
        "units": fit.UNITS,
        "outsideDomain": fit.OUTSIDE_DOMAIN,
        "depthDomain": list(fit.DEPTH_DOMAIN),
        "trainedOn": ["PLANTED-A", "PLANTED-B"],
        "export": [{"session": "PLANTED-A", "decimation": 64},
                   {"session": "PLANTED-B", "decimation": 64}],
        "classes": {
            "low": {"verdict": "adopted", "form": "quadratic",
                    "coefficients": {"a": 0.02, "b": 0.01}, "folds": []},
            "medium": {"verdict": "adopted", "form": "power",
                       "coefficients": {"a": 0.01, "p": 1.5}, "folds": []},
            "high": {"verdict": "refused", "folds": [],
                     "table": {"edges": list(fit.BAND_EDGES),
                               "medians": [0.003, None, 0.006, 0.009]}},
        },
    }
    artifact.update(overrides)
    return artifact


class WhatARefusalLooksLike(unittest.TestCase):
    def test_the_refused_class_names_the_table_it_kept(self):
        high = section(committed(), "high")
        self.assertIn("refused", high)
        self.assertIn("adopted no continuous form", high)
        self.assertIn("still answers", high)
        # v0.6's finding, on screen: refused is not unavailable.
        for edge in ("[0.50, 1.00)", "[1.00, 2.00)", "[2.00, 3.00)", "[3.00, 5.00)"):
            self.assertIn(edge, high)

    def test_a_refused_class_offers_no_path_to_coefficients(self):
        # The tooth the Swift type carries in its enum, carried here by there
        # being nothing on the page to read.
        high = section(committed(), "high")
        self.assertNotIn('class="coefficients"', high)
        self.assertIn("no coefficients to show", high)
        # And the adopted class does show them, so the assertion above is
        # about this class rather than about the renderer having no such code.
        self.assertIn('class="coefficients"', section(committed(), "low"))

    def test_a_band_without_samples_reads_as_one(self):
        page = render(planted())
        high = section(page, "high")
        self.assertIn("no samples", high)
        # Not a zero and not a blank: the two things that would invert the
        # thesis while looking tidy.
        self.assertNotIn("0.000000", high)

    def test_the_two_silences_read_differently(self):
        # "No form was adopted" and "nothing answers here" are different
        # findings, and the page cannot let them collapse into one another.
        page = committed()
        no_form = "adopted no continuous form"
        nothing_answers = "Outside this range nothing answers at all"
        # Different words, and in different places: the class's refusal sits
        # in the class's panel and still carries a table of numbers, while the
        # domain's silence sits above every class and carries none, because it
        # belongs to the domain rather than to any one of them.
        facts = page.split("<section")[0]
        high = section(page, "high")
        self.assertIn(nothing_answers, facts)
        self.assertNotIn(no_form, facts)
        self.assertIn(no_form, high)
        self.assertNotIn(nothing_answers, high)


class WhatThePageDoesNotDo(unittest.TestCase):
    def test_nothing_is_evaluated_in_the_browser(self):
        # The mechanical guard that there is no third reader: the page carries
        # no script to be one with, and nothing of ours to fetch. This is the
        # `rfile` assertion's shape and inherits its fragility -- a comment or
        # a namespaced doctype would turn it red for a non-reason -- and it is
        # kept anyway, because the invariant it pins is the rung's whole
        # architecture.
        page = committed()
        self.assertNotIn("<script", page)
        self.assertNotIn("://", page)

    def test_the_page_says_it_evaluates_nothing(self):
        # Otherwise "no estimate at any depth" reads as a curve someone forgot
        # rather than as this rung's decision. Commit 2 removes this line.
        self.assertIn("evaluates nothing", committed())
        self.assertIn("no estimate is computed at any depth", committed())

    def test_the_renderer_never_sees_a_request(self):
        # Stronger than serve.py's own version of this: there is no request
        # object in this module to read a body from in the first place.
        self.assertNotIn("rfile", inspect.getsource(view))


class WhatTheArtifactSays(unittest.TestCase):
    def test_the_classes_render_in_the_registered_order(self):
        page = committed()
        positions = [page.index(f">{name}<") for name in fit.CLASS_NAMES]
        self.assertEqual(positions, sorted(positions))

    def test_the_domain_reads_half_open(self):
        # The artifact carries two bare numbers; the Swift reader resolved the
        # inclusivity half-open, and a second consumer resolving it the other
        # way would put the two one depth apart.
        page = committed()
        self.assertIn("0.50 ≤ d &lt; 5.00 m", page)
        self.assertIn("half-open", page)

    def test_a_margin_carries_its_sign(self):
        # ModelProbe's third format exists because the sign is the finding:
        # the high class's margins flip across folds, which is exactly what
        # the unanimity bar refused to average away.
        high = section(committed(), "high")
        self.assertIn("+0.00", high)
        self.assertIn("-0.00", high)

    def test_an_adopted_form_shows_the_coefficients_it_is_evaluated_from(self):
        # Form-dependent, so the page shows what the artifact carries rather
        # than a fixed pair: quadratic has {a, b} and power has {a, p}.
        page = render(planted())
        low, medium = section(page, "low"), section(page, "medium")
        self.assertIn("<b>a</b>", low)
        self.assertIn("<b>b</b>", low)
        self.assertNotIn("<b>p</b>", low)
        self.assertIn("<b>p</b>", medium)
        self.assertNotIn("<b>b</b>", medium)

    def test_a_decimation_is_a_count_and_not_a_measurement(self):
        self.assertIn("decimation 64", committed())
        self.assertNotIn("decimation 64.000000", committed())

    def test_a_string_from_the_artifact_is_escaped(self):
        hostile = '<script>alert("x")</script> & <b>'
        page = render(planted(estimand=hostile))
        self.assertNotIn("<script", page)
        self.assertIn(html.escape(hostile, quote=True), page)

    def test_an_absent_class_reads_as_absent(self):
        artifact = planted()
        del artifact["classes"]["medium"]
        page = render(artifact)
        self.assertIn("carries no medium class", page)

    def test_the_committed_artifact_is_the_one_the_service_serves(self):
        # Read through fit's own reader, never re-parsed here -- the property
        # this whole rung is built on.
        with open(COMMITTED_ARTIFACT, encoding="utf-8") as handle:
            self.assertEqual(json.load(handle), fit.read_artifact(COMMITTED_ARTIFACT))


if __name__ == "__main__":
    unittest.main()
