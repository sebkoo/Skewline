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


if __name__ == "__main__":
    unittest.main()
