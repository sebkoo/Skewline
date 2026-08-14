"""The committed figures are what this generator produces, byte for byte.

An SVG is the one artifact in this repository nobody reads a diff of. The
guard is therefore not review but regeneration: every test below rebuilds from
`Fit/`'s own committed artifacts and compares against `docs/media/`, so a
hand-edited figure, a figure left stale after the generator changed, and a
figure whose bytes drifted with the filesystem's ordering all turn CI red in
the same way.

`span.py` is imported only to pin the two constants that must agree. Nothing
here recomputes a statistic: the point of the generator is that it cannot.
"""

import json
import os
import tempfile
import unittest

import span
import span_figure

HERE = os.path.dirname(os.path.abspath(__file__))
MEDIA = os.path.join(os.path.dirname(HERE), "docs", "media")


def committed(theme):
    with open(os.path.join(MEDIA, f"span-{theme}.svg"), encoding="utf-8") as f:
        return f.read()


class TheCommittedFiguresAreCurrent(unittest.TestCase):
    """The assertion the whole module exists for."""

    def test_both_themes_regenerate_to_the_committed_bytes(self):
        artifacts = span_figure.load_artifacts(HERE)
        for theme in ("light", "dark"):
            with self.subTest(theme=theme):
                self.assertEqual(
                    span_figure.build_svg(artifacts, theme),
                    committed(theme),
                    f"docs/media/span-{theme}.svg is not what "
                    f"span_figure.py produces from Fit/*.span.json -- "
                    f"regenerate it rather than editing it",
                )

    def test_writing_produces_the_same_bytes_as_building(self):
        """`write_figures` is what a person runs; `build_svg` is what the test
        above checks. If they could disagree, the checked path would not be the
        shipped one."""
        artifacts = span_figure.load_artifacts(HERE)
        with tempfile.TemporaryDirectory() as out:
            written = span_figure.write_figures(artifacts, out)
            self.assertEqual(len(written), 2)
            for path in written:
                theme = os.path.basename(path)[len("span-"):-len(".svg")]
                with open(path, encoding="utf-8") as handle:
                    self.assertEqual(handle.read(), committed(theme))


class TheOutputIsDeterministic(unittest.TestCase):
    """Byte-determinism is the claim; these are the three ways it could fail."""

    def test_two_builds_agree(self):
        artifacts = span_figure.load_artifacts(HERE)
        self.assertEqual(
            span_figure.build_svg(artifacts, "light"),
            span_figure.build_svg(artifacts, "light"),
        )

    def test_input_order_does_not_reach_the_output(self):
        """`load_artifacts` sorts by session, so a directory listing in a
        different order must still draw the same picture. Reversing the loaded
        list and re-sorting is the cheapest way to plant that."""
        artifacts = span_figure.load_artifacts(HERE)
        shuffled = list(reversed(artifacts))
        shuffled.sort(key=lambda a: a["measuredOn"][0])
        self.assertEqual(
            span_figure.build_svg(shuffled, "light"),
            span_figure.build_svg(artifacts, "light"),
        )

    def test_one_float_rule_for_every_coordinate(self):
        self.assertEqual(span_figure.num(12.0), "12")
        self.assertEqual(span_figure.num(12.00499), "12")
        self.assertEqual(span_figure.num(12.5), "12.5")
        self.assertEqual(span_figure.num(12.499), "12.5")
        self.assertEqual(span_figure.num(0.0), "0")
        self.assertEqual(span_figure.num(-0.001), "0", "no negative zero")


class WhatTheGeneratorRefuses(unittest.TestCase):
    def test_a_foreign_schema_is_refused_rather_than_skipped(self):
        with tempfile.TemporaryDirectory() as out:
            path = os.path.join(out, "wrong.span.json")
            with open(path, "w", encoding="utf-8") as handle:
                json.dump({"schema": "skewline-fit/1"}, handle)
            with self.assertRaises(ValueError) as caught:
                span_figure.load_artifacts(out)
            self.assertIn("skewline-span/1", str(caught.exception))

    def test_an_empty_directory_is_refused(self):
        with tempfile.TemporaryDirectory() as out:
            with self.assertRaises(ValueError):
                span_figure.load_artifacts(out)

    def test_artifacts_disagreeing_on_the_bands_cannot_share_an_axis(self):
        artifacts = span_figure.load_artifacts(HERE)
        bent = json.loads(json.dumps(artifacts[0]))
        bent["separationEdges"] = [0.0, 0.5, 1.0]
        with self.assertRaises(ValueError) as caught:
            span_figure.band_edges([artifacts[0], bent])
        self.assertIn("separationEdges", str(caught.exception))

    def test_the_cli_refuses_a_bad_invocation(self):
        self.assertEqual(span_figure.main([]), 64)
        self.assertEqual(span_figure.main(["--artifacts", HERE]), 64)


class TheFigureAgreesWithTheAnalysis(unittest.TestCase):
    """The generator draws `span.py`'s output, so the few facts it duplicates
    are pinned here rather than left to agree by habit."""

    def test_the_schema_tag_is_the_one_span_writes(self):
        self.assertEqual(span_figure.ARTIFACT_SCHEMA, span.ARTIFACT_SCHEMA)

    def test_the_classes_drawn_are_the_classes_fitted(self):
        self.assertEqual(
            sorted(span_figure.CLASS_ORDER), sorted(span.CLASS_NAMES)
        )

    def test_every_committed_ratio_reaches_the_drawing(self):
        """Twelve series of seven, and no cell quietly dropped."""
        artifacts = span_figure.load_artifacts(HERE)
        rows = span_figure.series(artifacts)
        self.assertEqual(len(rows), 12)
        self.assertEqual({len(r["ratios"]) for r in rows}, {7})

    def test_each_mode_gets_its_own_steps_rather_than_an_inversion(self):
        """Dark is not light flipped. If the two dicts were ever made equal,
        the dark figure would be carrying steps validated against the wrong
        surface."""
        light = span_figure.THEMES["light"]
        dark = span_figure.THEMES["dark"]
        self.assertNotEqual(light["surface"], dark["surface"])
        self.assertNotEqual(light["series"], dark["series"])
        for name in span_figure.CLASS_ORDER:
            self.assertIn(name, light["series"])
            self.assertIn(name, dark["series"])


if __name__ == "__main__":
    unittest.main()
