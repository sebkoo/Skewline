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


def ladder(chunk):
    """One class's evaluated ladder as `{depth: cell}`, so an assertion about
    what 5.00 does cannot be satisfied by a band edge elsewhere in the panel."""
    body = chunk.split('<table class="ladder">')[1].split("</table>")[0]
    rows = {}
    for row in body.split("<tr>")[2:]:      # [1] is the header row
        rows[row.split("<th>")[1].split("</th>")[0]] = (
            row.split("<td>")[1].split("</td>")[0]
        )
    return rows


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


class TheEvaluatedLadder(unittest.TestCase):
    """The rendered estimates. Every one goes through `fit.estimate`, so a
    refusal here is the refusal `Sources/Model` reports for the same class at
    the same depth -- and the depths are one registered list both readers use.
    """

    def test_every_registered_depth_gets_a_row_in_order(self):
        for name in fit.CLASS_NAMES:
            with self.subTest(name=name):
                rows = ladder(section(committed(), name))
                self.assertEqual(list(rows), [f"{d:.2f}" for d in fit.DEPTH_LADDER])

    def test_both_edges_of_the_domain_refuse_on_every_class(self):
        # What the ladder straddling both edges is for: 0.40 below, 5.00 the
        # upper bound the half-open reading excludes, 6.00 well outside. The
        # refusal is named as the domain's, and the sentence explaining it
        # stays above the classes -- `test_the_two_silences_read_differently`
        # is what keeps it there.
        for name in fit.CLASS_NAMES:
            rows = ladder(section(committed(), name))
            for depth in ("0.40", "5.00", "6.00"):
                with self.subTest(name=name, depth=depth):
                    self.assertIn("refused: outside the domain", rows[depth])
                    self.assertNotIn("0.0", rows[depth])
            self.assertNotIn("refused", rows["4.90"])

    def test_a_refused_class_still_answers_inside_the_domain(self):
        # v0.6's finding at the depth a reader actually asks about: refused is
        # not unavailable, and the number comes from the table it kept.
        rows = ladder(section(committed(), "high"))
        self.assertIn("0.006249", rows["2.00"])
        self.assertIn("table", rows["2.00"])
        # The band table above says the same number, which is the point: the
        # ladder is that table answered at a registered depth, not a new fit.
        self.assertIn("0.006249", section(committed(), "high"))

    def test_a_band_without_samples_reads_as_one_in_the_ladder(self):
        # The planted high class has no median in [1.00, 2.00). Not zero and
        # not blank: the two tidy-looking inversions of the thesis.
        rows = ladder(section(render(planted()), "high"))
        self.assertIn("no samples", rows["1.00"])
        self.assertNotIn("0.000000", rows["1.00"])
        # And the sampled bands beside it still answer, so "no samples" is
        # this band's finding rather than the table's.
        self.assertIn("0.009000", rows["3.00"])

    def test_a_class_the_page_cannot_evaluate_gets_a_sentence(self):
        # `fit.estimate` names four cases and no fifth, so a form it has no
        # arithmetic for raises rather than inventing a silence. The page
        # still shows everything the artifact carries for that class; what it
        # does not do is put a number where there is none.
        artifact = planted()
        artifact["classes"]["low"] = {"verdict": "adopted", "form": "cubic",
                                      "coefficients": {"a": 0.02}, "folds": []}
        low = section(render(artifact), "low")
        self.assertNotIn('<table class="ladder">', low)
        self.assertIn("No ladder is evaluated for this class", low)
        self.assertIn("<b>a</b>", low)          # still shown, not hidden
        self.assertIn("cubic", low)


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

    def test_the_page_says_whose_depths_it_evaluated(self):
        # The line this replaces said the page evaluated nothing, which was
        # this rung's decision until the ladder arrived. What has to stay said
        # is the part that survived: the depths are the repository's, and no
        # viewer's depth can reach this page at all.
        page = committed()
        closing = page.split('<p class="silence">')[1]
        self.assertIn("there is no depth on this page a viewer chose", closing)
        self.assertNotIn("no estimate is computed at any depth", page)
        # Not a sweep for "evaluates nothing": the shell's own comment says the
        # BROWSER evaluates nothing, which is still true and is a different
        # claim. A wider assertion here would go red for that non-reason.

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

    def test_a_fold_names_its_holdout_by_the_block_devlog_writes(self):
        # The fold table is the widest thing on the page and the column that
        # fell off the card at the default width was the adopted form's
        # margin -- the evidence. The identifier loses nothing: all four are
        # on the same page, in full, under TRAINED ON.
        page = committed()
        session = "931A8965-D191-4A08-B6D9-DC60EA2AA606"
        self.assertIn("931A8965…", section(page, "low"))
        self.assertNotIn(session, section(page, "low"))
        self.assertIn(session, page.split("<section")[0])

    def test_a_holdout_that_is_not_a_uuid_is_printed_whole(self):
        # Shortening an arbitrary name could make two rows read identically,
        # and every row here is a different container's evidence.
        artifact = planted()
        artifact["classes"]["high"]["folds"] = [
            {"holdout": "PLANTED-A", "table": 0.004, "forms": {}},
            {"holdout": "PLANTED-B", "table": 0.005, "forms": {}},
        ]
        high = section(render(artifact), "high")
        self.assertIn("PLANTED-A", high)
        self.assertIn("PLANTED-B", high)

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
