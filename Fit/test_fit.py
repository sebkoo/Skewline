"""Synthetic-recovery tests for the fit harness.

Every test plants known model parameters, generates synthetic observations
whose |delta| median is exactly the planted sigma(d) -- a multiplicative
lognormal factor with median 1 -- and requires the fit to recover what was
planted. No real observation file is touched: real exports derive from home
captures and never enter the repository.

Everything is seeded `default_rng`: a failure reproduces exactly.
"""

import json
import os
import tempfile
import unittest

import numpy as np

import fit

# Anchored to this file and never to the working directory: the mirror check
# below FAILS rather than skips when the declaration is missing, so a path
# resolved against a caller's cwd would turn "run from somewhere else" into a
# red that reads exactly like "the declaration moved". `test_serve.py`'s
# `HERE` is the same shape, and `ModelArtifactTests` does this in the other
# language with `#filePath`.
HERE = os.path.dirname(os.path.abspath(__file__))
PROBE_SOURCE = os.path.join(HERE, os.pardir, "Sources", "ModelProbe", "ModelProbe.swift")
LADDER_DECLARATION = "static let depths: [Double] = ["


def synthetic(rng, n, sigma_fn, noise=0.4):
    """Depths uniform over the domain; |delta| = sigma(d) times a factor
    whose median is exactly 1, so the planted sigma IS the conditional
    median the fit claims to estimate."""
    depth = rng.uniform(fit.DEPTH_DOMAIN[0], fit.DEPTH_DOMAIN[1], n)
    factor = np.exp(rng.normal(0.0, noise, n))
    return depth, sigma_fn(depth) * factor


class RegisteredStatistics(unittest.TestCase):
    def test_upper_median_matches_the_swift_precedent(self):
        self.assertEqual(fit.upper_median([3, 1, 2]), 2)
        self.assertEqual(fit.upper_median([1, 2, 3, 4]), 3)
        with self.assertRaises(ValueError):
            fit.upper_median([])

    def test_weighted_median_reduces_to_upper_median(self):
        rng = np.random.default_rng(0)
        for n in (1, 2, 3, 10, 101):
            values = rng.normal(0, 1, n)
            self.assertEqual(
                fit.weighted_median(values, np.ones(n)),
                fit.upper_median(values),
            )


class CoefficientRecovery(unittest.TestCase):
    def test_affine_recovery(self):
        rng = np.random.default_rng(1)
        depth, abs_delta = synthetic(rng, 50_000, lambda d: 0.005 + 0.01 * d)
        coefficients = fit.fit_form("affine", depth, abs_delta)
        self.assertAlmostEqual(coefficients["a"], 0.005, delta=0.0005)
        self.assertAlmostEqual(coefficients["b"], 0.01, delta=0.0005)

    def test_quadratic_recovery(self):
        rng = np.random.default_rng(2)
        depth, abs_delta = synthetic(rng, 50_000, lambda d: 0.003 + 0.002 * d * d)
        coefficients = fit.fit_form("quadratic", depth, abs_delta)
        self.assertAlmostEqual(coefficients["a"], 0.003, delta=0.0005)
        self.assertAlmostEqual(coefficients["b"], 0.002, delta=0.0002)

    def test_power_recovery(self):
        rng = np.random.default_rng(3)
        depth, abs_delta = synthetic(rng, 50_000, lambda d: 0.004 * d ** 1.7)
        coefficients = fit.fit_form("power", depth, abs_delta)
        self.assertAlmostEqual(coefficients["p"], 1.7, delta=0.051)
        self.assertAlmostEqual(coefficients["a"], 0.004, delta=0.0004)

    def test_fit_tracks_the_median_not_the_mean(self):
        # Heavily asymmetric noise: lognormal with sigma 1.5 has median 1
        # but mean e^1.125 (about 3.1x). A silent mean-regression would
        # recover a curve three times too high; the median fit must not.
        rng = np.random.default_rng(4)
        depth, abs_delta = synthetic(
            rng, 200_000, lambda d: 0.005 + 0.01 * d, noise=1.5
        )
        coefficients = fit.fit_form("affine", depth, abs_delta)
        planted = 0.005 + 0.01 * fit.POSITIVITY_GRID
        recovered = fit.predict("affine", coefficients, fit.POSITIVITY_GRID)
        relative = np.abs(recovered - planted) / planted
        self.assertLess(float(relative.max()), 0.15)

    def test_decimation_invariance(self):
        # The seam's core claim: a 1-in-64 systematic decimation of one
        # population fits to the same model as the full population, AT THE
        # SCALE THE SEAM ARGUES -- tens of thousands of retained samples.
        # The invariant is the curve, not the raw coefficients (parameters
        # trade off along the fit), and the population leaves 20,000 after
        # decimation; a decimated sample well below the argued scale drifts
        # by honest sampling error, which is not this test's claim.
        rng = np.random.default_rng(5)
        depth, abs_delta = synthetic(rng, 1_280_000, lambda d: 0.005 + 0.01 * d)
        full = fit.fit_form("affine", depth, abs_delta)
        decimated = fit.fit_form("affine", depth[::64], abs_delta[::64])
        full_curve = fit.predict("affine", full, fit.POSITIVITY_GRID)
        decimated_curve = fit.predict("affine", decimated, fit.POSITIVITY_GRID)
        relative = np.abs(decimated_curve - full_curve) / full_curve
        self.assertLess(float(relative.max()), 0.05)


class RegisteredSelection(unittest.TestCase):
    def containers(self, sigma_fn, n=20_000, noise=0.4, seed=10):
        made = []
        for i in range(4):
            rng = np.random.default_rng(seed + i)
            depth, abs_delta = synthetic(rng, n, sigma_fn, noise=noise)
            made.append((f"container-{i}", depth, abs_delta))
        return made

    def test_selection_adopts_the_planted_form(self):
        result = fit.select_for_class(
            self.containers(lambda d: 0.01 * d ** 1.5)
        )
        self.assertEqual(result["verdict"], "adopted")
        self.assertEqual(result["form"], "power")
        for fold in result["folds"]:
            self.assertLess(fold["forms"]["power"]["metric"], fold["table"])

    def test_selection_refuses_band_constant_data(self):
        # Data the incumbent describes exactly: piecewise-constant per band.
        # No continuous form may be adopted; the table remains the model.
        table = {
            "edges": list(fit.BAND_EDGES),
            "medians": [0.004, 0.008, 0.016, 0.032],
        }
        result = fit.select_for_class(
            self.containers(lambda d: fit.predict("table", table, d))
        )
        self.assertEqual(result["verdict"], "refused")
        self.assertNotIn("form", result)
        self.assertEqual(result["table"]["edges"], list(fit.BAND_EDGES))

    def test_positivity_gate_disqualifies_a_negative_curve(self):
        # Nearly all mass far and steeply rising, a sliver of tiny residuals
        # near: the L1 affine fit crosses zero inside the domain and must be
        # disqualified in every fold, whatever the other forms do.
        made = []
        for i in range(4):
            rng = np.random.default_rng(20 + i)
            far = rng.uniform(3.0, 5.0, 19_000)
            near = rng.uniform(0.5, 0.6, 1_000)
            depth = np.concatenate([far, near])
            sigma = np.maximum(0.01 * (depth - 2.9), 0.0001)
            abs_delta = sigma * np.exp(rng.normal(0.0, 0.4, depth.size))
            made.append((f"container-{i}", depth, abs_delta))
        result = fit.select_for_class(made)
        for fold in result["folds"]:
            self.assertIn("disqualified", fold["forms"]["affine"])

    def test_selection_needs_at_least_two_containers(self):
        rng = np.random.default_rng(6)
        depth, abs_delta = synthetic(rng, 100, lambda d: 0.01 * d)
        with self.assertRaises(ValueError):
            fit.select_for_class([("only", depth, abs_delta)])


class Artifact(unittest.TestCase):
    def test_round_trip_including_the_mixed_outcome(self):
        selection = RegisteredSelection()
        adopted = fit.select_for_class(
            selection.containers(lambda d: 0.01 * d ** 1.5, n=5_000)
        )
        table = {
            "edges": list(fit.BAND_EDGES),
            "medians": [0.004, 0.008, 0.016, 0.032],
        }
        refused = fit.select_for_class(
            selection.containers(
                lambda d: fit.predict("table", table, d), n=5_000, seed=30
            )
        )
        self.assertEqual(adopted["verdict"], "adopted")
        self.assertEqual(refused["verdict"], "refused")

        artifact = fit.build_artifact(
            {0: refused, 1: refused, 2: adopted},
            [{"session": "S", "decimation": 64}],
        )
        self.assertEqual(artifact["schema"], fit.ARTIFACT_SCHEMA)
        self.assertEqual(artifact["estimand"], fit.ESTIMAND)
        self.assertEqual(artifact["units"], "meters")
        self.assertEqual(artifact["outsideDomain"], "refuse")
        self.assertIn("table", artifact["classes"]["low"])
        self.assertIn("coefficients", artifact["classes"]["high"])

        with tempfile.TemporaryDirectory() as directory:
            path = os.path.join(directory, "model.json")
            fit.write_artifact(path, artifact)
            self.assertEqual(fit.read_artifact(path), json.loads(json.dumps(artifact)))

    def test_wrong_schema_is_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            path = os.path.join(directory, "model.json")
            with open(path, "w", encoding="utf-8") as handle:
                json.dump({"schema": "something-else/1"}, handle)
            with self.assertRaises(ValueError):
                fit.read_artifact(path)


OBSERVATION_FIXTURE = """\
# skewline-observations/1
# session 2110CDA9-TEST
# separations 1,5
# nominal-frame-interval 0.03333333333333333
# band-edges 0.5,1.0,2.0,3.0,5.0
# decimation 64
# survivors k=1 class=0 band=0 167224
# survivors k=1 class=2 band=1 54321
# columns k,delta_t,class,depth,delta
1,0.0333,2,1.25,0.004
1,0.0333,0,0.75,-0.02
5,0.1666,2,1.25,0.009
1,0.0334,2,1.5,-0.003
"""


# The same four rows as above, in the widened schema: identical first five
# columns, eight geometry columns appended. The fit must read this file to
# exactly the same numbers, which is what "the first five are frozen" means.
GEOMETRY_FIXTURE = """\
# skewline-observations/2
# session 2110CDA9-TEST
# separations 1,5
# nominal-frame-interval 0.03333333333333333
# band-edges 0.5,1.0,2.0,3.0,5.0
# decimation 1
# sampling pair-stride
# pair-stride 8
# pairs-seen 100
# pairs-kept 13
# survivors k=1 class=0 band=0 167224
# survivors k=1 class=2 band=1 54321
# intrinsics 36 190.41724 190.41724 128.07576 95.83778
# intrinsics 44 178.35194 178.35194 128.48602 95.59109
# columns k,delta_t,class,depth,delta,src_frame,tgt_frame,src_x,src_y,tgt_x,tgt_y,rt_dx,rt_dy
1,0.0333,2,1.25,0.004,36,37,10,20,10,20,0.01,0.02
1,0.0333,0,0.75,-0.02,36,37,11,20,11,20,-0.03,0.01
5,0.1666,2,1.25,0.009,44,49,12,21,12,21,0.02,-0.02
1,0.0334,2,1.5,-0.003,44,45,13,21,13,21,0.00,0.00
"""


class ObservationFiles(unittest.TestCase):
    def write_fixture(self, directory, text=OBSERVATION_FIXTURE):
        path = os.path.join(directory, "observations.csv")
        with open(path, "w", encoding="utf-8") as handle:
            handle.write(text)
        return path

    def test_reader_parses_the_export_format(self):
        with tempfile.TemporaryDirectory() as directory:
            observations = fit.read_observations(self.write_fixture(directory))
        self.assertEqual(observations["session"], "2110CDA9-TEST")
        self.assertEqual(observations["metadata"]["decimation"], "64")
        self.assertEqual(
            observations["survivors"],
            {"k=1 class=0 band=0": 167224, "k=1 class=2 band=1": 54321},
        )
        np.testing.assert_array_equal(observations["k"], [1, 1, 5, 1])
        np.testing.assert_array_equal(observations["class"], [2, 0, 2, 2])
        np.testing.assert_allclose(observations["depth"], [1.25, 0.75, 1.25, 1.5])
        np.testing.assert_allclose(observations["delta"], [0.004, -0.02, 0.009, -0.003])

    def test_wrong_schema_tag_is_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            path = self.write_fixture(
                directory, "# some-other-format/9\n1,0.03,2,1.0,0.001\n"
            )
            with self.assertRaises(ValueError):
                fit.read_observations(path)

    def test_load_class_containers_keeps_k1_and_splits_by_class(self):
        with tempfile.TemporaryDirectory() as directory:
            containers, provenance = fit.load_class_containers(
                [self.write_fixture(directory)]
            )
        session, depth, abs_delta = containers[2][0]
        self.assertEqual(session, "2110CDA9-TEST")
        np.testing.assert_allclose(depth, [1.25, 1.5])  # the k=5 row is gone
        np.testing.assert_allclose(abs_delta, [0.004, 0.003])  # |delta|
        np.testing.assert_allclose(containers[0][0][2], [0.02])
        self.assertEqual(containers[1][0][1].size, 0)
        self.assertEqual(provenance, [{"session": "2110CDA9-TEST", "decimation": 64}])

    def test_the_widened_schema_reads_to_the_same_first_five_columns(self):
        # The freeze, stated as an equality rather than as a comment: /2 is
        # /1 with columns appended, so the fit's own inputs are untouched by
        # the widening and `Fit/model.json` stays reproducible from the files
        # it was fitted from.
        with tempfile.TemporaryDirectory() as directory:
            narrow = fit.read_observations(self.write_fixture(directory))
            wide = fit.read_observations(
                self.write_fixture(directory, text=GEOMETRY_FIXTURE)
            )
        self.assertEqual(narrow["schema"], fit.SCHEMA_TAG)
        self.assertEqual(wide["schema"], fit.GEOMETRY_SCHEMA_TAG)
        for name in fit.COLUMNS_V1:
            with self.subTest(column=name):
                np.testing.assert_allclose(wide[name], narrow[name])

    def test_the_widened_schema_carries_geometry_and_intrinsics(self):
        with tempfile.TemporaryDirectory() as directory:
            wide = fit.read_observations(
                self.write_fixture(directory, text=GEOMETRY_FIXTURE)
            )
        np.testing.assert_array_equal(wide["src_frame"], [36, 36, 44, 44])
        np.testing.assert_array_equal(wide["tgt_frame"], [37, 37, 49, 45])
        np.testing.assert_array_equal(wide["src_x"], [10, 11, 12, 13])
        np.testing.assert_allclose(wide["rt_dx"], [0.01, -0.03, 0.02, 0.0])
        self.assertEqual(
            wide["intrinsics"][36], (190.41724, 190.41724, 128.07576, 95.83778)
        )
        self.assertEqual(sorted(wide["intrinsics"]), [36, 44])
        # k counts eligible frames, so the gap is not the separation. The row
        # with k=5 spans frames 44 to 49 here; a reader that assumed
        # tgt - src == k would be wrong on any container with a gap.
        self.assertEqual(int(wide["tgt_frame"][3] - wide["src_frame"][3]), 1)
        self.assertEqual(int(wide["k"][2]), 5)

    def test_a_tag_that_disagrees_with_its_column_count_is_rejected(self):
        # The /2 tag on /1 rows: the tag alone decides the width, so this
        # cannot be read as a narrow file that happens to be tagged wrongly.
        text = GEOMETRY_FIXTURE.replace(
            "# columns k,delta_t,class,depth,delta,"
            "src_frame,tgt_frame,src_x,src_y,tgt_x,tgt_y,rt_dx,rt_dy",
            "# columns k,delta_t,class,depth,delta",
        )
        text = "\n".join(
            line for line in text.splitlines() if not line[:1].isdigit()
        ) + "\n1,0.0333,2,1.25,0.004\n"
        with tempfile.TemporaryDirectory() as directory:
            with self.assertRaises(ValueError):
                fit.read_observations(self.write_fixture(directory, text=text))

    def test_a_reordered_columns_header_is_rejected(self):
        # Written since v0.6 and never read until now. Every consumer is
        # positional, so a writer that swapped two columns would be a green
        # suite and wrong numbers everywhere.
        text = OBSERVATION_FIXTURE.replace(
            "# columns k,delta_t,class,depth,delta",
            "# columns k,delta_t,class,delta,depth",
        )
        with tempfile.TemporaryDirectory() as directory:
            with self.assertRaises(ValueError):
                fit.read_observations(self.write_fixture(directory, text=text))


class TheRefuser(unittest.TestCase):
    """`fit.estimate`, whose four cases mirror `Sources/Model`'s `Estimate`.

    `predict` is the shared evaluator and not a shared refuser: it answers
    wherever it is asked and returns one NaN for two different silences, which
    is why these are tests of a second function rather than of that one.
    """

    ADOPTED = {"verdict": "adopted", "form": "quadratic",
               "coefficients": {"a": 0.02, "b": 0.01}, "folds": []}
    REFUSED = {"verdict": "refused", "folds": [],
               "table": {"edges": list(fit.BAND_EDGES),
                         "medians": [0.003, None, 0.006, 0.009]}}

    def test_an_adopted_class_answers_from_its_form(self):
        answer = fit.estimate(self.ADOPTED, 2.0)
        self.assertEqual(answer["case"], fit.FROM_ADOPTED_FORM)
        self.assertAlmostEqual(answer["meters"], 0.02 + 0.01 * 4.0)

    def test_a_refused_class_still_answers_from_the_table_it_kept(self):
        # v0.6's finding, in the evaluator: refused is not unavailable.
        answer = fit.estimate(self.REFUSED, 2.5)
        self.assertEqual(answer["case"], fit.FROM_BANDED_TABLE)
        self.assertEqual(answer["meters"], 0.006)

    def test_a_band_without_samples_is_its_own_silence(self):
        answer = fit.estimate(self.REFUSED, 1.5)
        self.assertEqual(answer["case"], fit.REFUSED_BAND_WITHOUT_SAMPLES)
        self.assertIsNone(answer["meters"])

    def test_outside_the_domain_nothing_answers_for_either_verdict(self):
        for model in (self.ADOPTED, self.REFUSED):
            for depth in (0.4, 6.0):
                with self.subTest(verdict=model["verdict"], depth=depth):
                    answer = fit.estimate(model, depth)
                    self.assertEqual(answer["case"],
                                     fit.REFUSED_OUTSIDE_DEPTH_DOMAIN)
                    self.assertIsNone(answer["meters"])
        # And `predict` would have answered there, which is the whole reason
        # this refuser had to be written.
        self.assertTrue(np.isfinite(
            fit.predict("quadratic", self.ADOPTED["coefficients"], 6.0)
        ))

    def test_the_two_domains_disagree_at_the_top_endpoint(self):
        # One pair of endpoints, two questions. The gate asks "may this be
        # adopted" and is closed -- 5.0 is on its grid, because a form that
        # goes non-positive at the top of the fitted range is disqualified
        # whether or not anyone asks there. The refuser asks "does a consumer
        # get a number" and is half-open -- the last band is [3.0, 5.0) and
        # 5.0 falls in none. The constants are one object; this is what
        # enforces the difference.
        self.assertEqual(float(fit.POSITIVITY_GRID[-1]), fit.DEPTH_DOMAIN[1])
        self.assertTrue(fit.positive_on_domain("quadratic",
                                               self.ADOPTED["coefficients"]))
        self.assertEqual(fit.estimate(self.ADOPTED, 4.9)["case"],
                         fit.FROM_ADOPTED_FORM)
        self.assertEqual(fit.estimate(self.ADOPTED, 5.0)["case"],
                         fit.REFUSED_OUTSIDE_DEPTH_DOMAIN)
        self.assertEqual(fit.estimate(self.REFUSED, 5.0)["case"],
                         fit.REFUSED_OUTSIDE_DEPTH_DOMAIN)

    def test_what_it_cannot_name_raises_rather_than_inventing_a_silence(self):
        # Four cases and no fifth: an unnamed verdict, a form with no
        # arithmetic here, and a table that does not span the domain -- the
        # last of which the Swift decoder refuses an artifact over.
        for model in (
            {"verdict": "pending", "folds": []},
            {"verdict": "adopted", "form": "cubic", "coefficients": {"a": 1.0}},
            {"verdict": "adopted", "form": "quadratic", "coefficients": {"a": 1.0}},
            {"verdict": "refused",
             "table": {"edges": [0.5, 1.0], "medians": [0.003]}},
        ):
            with self.subTest(model=model):
                with self.assertRaises(ValueError):
                    fit.estimate(model, 2.0)


class TheSharedLadder(unittest.TestCase):
    """The ladder is registered in docs/DEVLOG.md and declared here; Swift
    carries the same eight numbers because it cannot read a Python constant."""

    def test_the_ladder_straddles_both_edges_of_the_answering_domain(self):
        low, high = fit.ANSWERING_DOMAIN
        self.assertEqual(list(fit.DEPTH_LADDER), sorted(fit.DEPTH_LADDER))
        self.assertTrue(any(depth < low for depth in fit.DEPTH_LADDER))
        self.assertTrue(any(depth > high for depth in fit.DEPTH_LADDER))
        # Both endpoints themselves, because the top one is where the two
        # domains disagree and a ladder that skipped it would hide that.
        self.assertIn(low, fit.DEPTH_LADDER)
        self.assertIn(high, fit.DEPTH_LADDER)

    def test_the_swift_mirror_carries_the_registered_ladder(self):
        # Copying the ladder into a fixture would create a second copy to
        # drift, so this reads the declaration itself -- ModelArtifactTests'
        # move in the other direction. It is a positive assertion on one
        # declaration, so its failure mode is going red rather than passing
        # quietly, and a reformatted declaration going red is the price of
        # never having a silent green.
        with open(PROBE_SOURCE, encoding="utf-8") as handle:
            source = handle.read()
        self.assertIn(LADDER_DECLARATION, source,
                      f"{PROBE_SOURCE} no longer declares the mirrored ladder")
        literal = source.split(LADDER_DECLARATION, 1)[1].split("]", 1)[0]
        # Parsed floats in order: text would go red on 0.4 against 0.40 for no
        # reason, and a set would drop the order both readers render.
        mirrored = tuple(float(part) for part in literal.split(","))
        self.assertEqual(mirrored, tuple(float(d) for d in fit.DEPTH_LADDER))


if __name__ == "__main__":
    unittest.main()
