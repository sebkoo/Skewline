"""Planted-data tests for the span analysis.

Every test plants a residual structure whose answer is known before the code
runs: a per-frame-pair offset must cancel, independent residuals must not, and
a depth-scaled population with no pair structure must read 1 under the
registered null and only under it. No real observation file is touched -- `/2`
exports derive from home captures, carry a frame index and a pixel per row, and
never enter this repository.

Everything is seeded `default_rng`: a failure reproduces exactly.
"""

import contextlib
import io
import json
import os
import tempfile
import unittest

import numpy as np

import fit
import span

HERE = os.path.dirname(os.path.abspath(__file__))

# One synthetic camera, shared by the writers below. Focal lengths are
# per-frame in the format; these fixtures use one value per frame deliberately
# so that a separation is hand-checkable.
FX = FY = 200.0
CX = CY = 128.0


def geometry_text(rows, sampling="pair-stride", frames=None, tag=None, session="PLANTED-TEST"):
    """A `/2` file: the header the probe writes, then the rows given."""
    frames = frames if frames is not None else sorted({int(r[5]) for r in rows})
    header = [
        f"# {tag or span.SCHEMA_TAG}",
        f"# session {session}",
        "# separations 1",
        "# nominal-frame-interval 0.03333333333333333",
        "# band-edges 0.5,1.0,2.0,3.0,5.0",
        "# forward-backward-radius 1.0",
        "# decimation 1",
        f"# sampling {sampling}",
        "# pair-stride 8",
        f"# pairs-seen {len(frames)}",
        f"# pairs-kept {len(frames)}",
    ]
    for frame in frames:
        header.append(f"# intrinsics {frame} {FX} {FY} {CX} {CY}")
    header.append(f"# columns {','.join(fit.COLUMNS_V2)}")
    body = [",".join(str(value) for value in row) for row in rows]
    return "\n".join(header + body) + "\n"


def planted_rows(
    rng,
    pairs=8,
    per_pair=400,
    common=0.0,
    independent=0.01,
    depth_scale=0.0,
    depth_low=1.0,
    depth_high=1.2,
):
    """Rows whose residual is `common_p + independent noise`.

    `common` is a per-frame-pair offset -- the common-mode term a difference
    must remove. `depth_scale` adds a depth-proportional independent term, the
    shape that makes a band-matched null read cancellation that is not there.
    """
    rows = []
    for pair in range(pairs):
        source = pair * 10
        target = source + 1
        offset = rng.normal(0.0, common) if common else 0.0
        for index in range(per_pair):
            depth = rng.uniform(depth_low, depth_high)
            scale = independent + depth_scale * depth
            residual = offset + rng.normal(0.0, scale)
            x = int(rng.integers(0, 256))
            y = int(rng.integers(0, 192))
            rows.append((
                1, 0.0333, 2, round(depth, 6), round(residual, 9),
                source, target, x, y, x, y, 0.01, 0.01,
            ))
    return rows


def written(rows, directory, **kwargs):
    path = os.path.join(directory, "geometry.csv")
    with open(path, "w", encoding="utf-8") as handle:
        handle.write(geometry_text(rows, **kwargs))
    return path


def ratios(observations, class_index=2, seed=span.SEED):
    cells = span.cell_ratios(observations, class_index, seed=seed)["cells"]
    return [cell["ratio"] for cell in cells if cell["ratio"] is not None]


class TheRegisteredGeometry(unittest.TestCase):
    def test_separation_bands_are_half_open_and_count_their_outside(self):
        edges = span.SEPARATION_EDGES
        band = span.separation_band(np.array([
            edges[0], edges[1] - 1e-9, edges[1], edges[-1], edges[-1] + 1.0, -1.0
        ]))
        self.assertEqual(list(band[:3]), [0, 0, 1])
        # The top edge is outside, exactly as the depth bands' last edge is.
        self.assertEqual(band[3], -1)
        self.assertEqual(band[4], -1)
        self.assertEqual(band[5], -1)

    def test_camera_coordinates_use_each_frames_own_intrinsics(self):
        rows = [
            (1, 0.0333, 2, 2.0, 0.001, 10, 11, CX + 100, CY, CX + 100, CY, 0.0, 0.0),
            (1, 0.0333, 2, 2.0, 0.001, 20, 21, CX + 100, CY, CX + 100, CY, 0.0, 0.0),
        ]
        text = geometry_text(rows).replace(
            f"# intrinsics 20 {FX} {FY} {CX} {CY}",
            f"# intrinsics 20 {FX / 2} {FY / 2} {CX} {CY}",
        )
        with tempfile.TemporaryDirectory() as directory:
            path = os.path.join(directory, "geometry.csv")
            with open(path, "w", encoding="utf-8") as handle:
                handle.write(text)
            observations = span.read_geometry(path)
        x, _ = span.camera_xy(observations)
        # Same pixel, same depth, half the focal length -- twice the offset.
        self.assertAlmostEqual(x[0], 100 * 2.0 / FX)
        self.assertAlmostEqual(x[1], 2 * x[0])

    def test_a_row_whose_frame_has_no_intrinsics_fails_loudly(self):
        rows = planted_rows(np.random.default_rng(0), pairs=1, per_pair=4)
        text = geometry_text(rows)
        text = "\n".join(
            line for line in text.splitlines() if not line.startswith("# intrinsics")
        ) + "\n"
        with tempfile.TemporaryDirectory() as directory:
            path = os.path.join(directory, "geometry.csv")
            with open(path, "w", encoding="utf-8") as handle:
                handle.write(text)
            with self.assertRaises(ValueError):
                span.read_geometry(path)


class WhatThisAnalysisRefuses(unittest.TestCase):
    def test_a_v1_file_is_refused(self):
        with tempfile.TemporaryDirectory() as directory:
            path = os.path.join(directory, "observations.csv")
            with open(path, "w", encoding="utf-8") as handle:
                handle.write(
                    "# skewline-observations/1\n"
                    "# session S\n"
                    "# columns k,delta_t,class,depth,delta\n"
                    "1,0.0333,2,1.25,0.004\n"
                )
            with self.assertRaises(ValueError):
                span.read_geometry(path)

    def test_a_file_decimated_within_pairs_is_refused(self):
        # The registered refusal that matters most: this file has every column
        # the analysis needs and a sampling rule that aliases the covariate.
        rows = planted_rows(np.random.default_rng(1), pairs=2, per_pair=8)
        with tempfile.TemporaryDirectory() as directory:
            path = written(rows, directory, sampling="every-nth")
            with self.assertRaises(ValueError) as raised:
                span.read_geometry(path)
        self.assertIn("pair-stride", str(raised.exception))

    def one_row(self, source, target):
        return (1, 0.0333, 2, 1.0, 0.001, source, target, 10, 10, 10, 10, 0.0, 0.0)

    def test_a_star_of_frame_pairs_is_refused(self):
        # Every pair shares frame 0, so no null partner sharing no frame with
        # any same-pair draw can ever be drawn: the estimand is undefined, not
        # merely thin. `read_geometry` still succeeds -- `lateral_summary`
        # needs no partner pair at all -- but `cell_ratios`, the null's own
        # entry point, refuses before any per-class sampling runs.
        rows = [self.one_row(0, 1), self.one_row(0, 2), self.one_row(0, 3), self.one_row(0, 4)]
        with tempfile.TemporaryDirectory() as directory:
            observations = span.read_geometry(written(rows, directory))
        self.assertFalse(span.has_disjoint_pair(observations))
        with self.assertRaises(ValueError) as raised:
            span.cell_ratios(observations, 2)
        self.assertIn("no frame", str(raised.exception))
        self.assertNotIn("insufficient", str(raised.exception).lower())

    def test_a_triangle_of_frame_pairs_is_refused(self):
        # Exactly three distinct pairs over exactly three frames -- the one
        # other shape a pairwise-intersecting family of two-element sets can
        # take besides a star. {0,1}, {1,2}, {0,2}: every two share a frame,
        # but no single frame is common to all three.
        rows = [self.one_row(0, 1), self.one_row(1, 2), self.one_row(0, 2)]
        with tempfile.TemporaryDirectory() as directory:
            observations = span.read_geometry(written(rows, directory))
        self.assertFalse(span.has_disjoint_pair(observations))
        with self.assertRaises(ValueError) as raised:
            span.cell_ratios(observations, 2)
        self.assertIn("no frame", str(raised.exception))

    def test_a_file_with_one_disjoint_pair_proceeds(self):
        # The mirror: two pairs sharing no frame at all is enough, and must
        # not be refused -- by the predicate or by `cell_ratios`.
        rows = [self.one_row(0, 1), self.one_row(10, 11)]
        with tempfile.TemporaryDirectory() as directory:
            observations = span.read_geometry(written(rows, directory))
        self.assertTrue(span.has_disjoint_pair(observations))
        span.cell_ratios(observations, 2)  # must not raise

    def test_an_unregistered_threshold_raises_rather_than_answering(self):
        # Both thresholds are filled now, so this pins the BEHAVIOUR rather
        # than the state it used to observe: a threshold that is not set
        # refuses instead of quietly answering. Worth keeping after the fill,
        # because it is what a future unset value would run into.
        with self.assertRaises(ValueError):
            span._registered(None, "CANCELLATION_MARGIN")
        with self.assertRaises(ValueError):
            span._registered_clearance(None)

    def test_the_registered_thresholds_are_the_values_that_were_filled(self):
        self.assertEqual(span.CANCELLATION_MARGIN, 0.10)
        self.assertEqual(span.LATERAL_CLEARANCE_MARGIN, 0.50)
        self.assertGreater(
            span.LATERAL_CLEARANCE_MARGIN, span.LATERAL_CLEARANCE_FLOOR
        )

    def test_the_cancellation_boundary_is_the_registered_one(self):
        # ratio < 0.90 cancels with margin; at or above it does not.
        self.assertEqual(span.cell_verdict({"ratio": 0.89}), span.CANCELS_WITH_MARGIN)
        self.assertEqual(
            span.cell_verdict({"ratio": 0.95}), span.CANCELS_WITHOUT_MARGIN
        )
        self.assertEqual(span.cell_verdict({"ratio": 1.0}), span.DOES_NOT_CANCEL)
        self.assertEqual(span.cell_verdict({"ratio": 1.2}), span.ANTI_CORRELATED)
        self.assertEqual(span.cell_verdict({"ratio": None}), span.INSUFFICIENT_PAIRS)


class WhatTheStatisticMeasures(unittest.TestCase):
    def test_a_common_mode_offset_cancels(self):
        # The claim the rung exists to test, on data where the answer is known:
        # a per-frame-pair offset ten times the independent noise vanishes from
        # every same-pair difference and survives in every permuted one.
        rng = np.random.default_rng(10)
        rows = planted_rows(rng, common=0.10, independent=0.01)
        with tempfile.TemporaryDirectory() as directory:
            observations = span.read_geometry(written(rows, directory))
        found = ratios(observations)
        self.assertTrue(found)
        self.assertLess(max(found), 0.5)

    def test_independent_residuals_do_not_cancel(self):
        # The mirror, and the one that matters: a fabricated CANCELLATION is
        # the overclaim this suite must be able to catch.
        rng = np.random.default_rng(11)
        rows = planted_rows(rng, common=0.0, independent=0.01)
        with tempfile.TemporaryDirectory() as directory:
            observations = span.read_geometry(written(rows, directory))
        found = ratios(observations)
        self.assertTrue(found)
        np.testing.assert_allclose(found, np.ones(len(found)), atol=0.12)

    def test_a_depth_scaled_population_reads_one_under_the_registered_null(self):
        # The executable form of "match on fine depth, never on band", and the
        # fixture has to encode the real mechanism or it proves nothing: in a
        # real frame pair the pixels sample ONE scene, so their depths are
        # close to each other and far from another pair's. Here each pair sits
        # in a narrow depth window and the windows are spread across the
        # domain, with residual scale proportional to depth and NO common-mode
        # term at all -- so the honest answer is 1.
        #
        # A null that ignored depth would draw partners from every window at
        # once, inflating itself against same-pair differences drawn from one
        # window, and would read cancellation that is not there. That is the
        # failure this asserts against, and dropping the match turns it red.
        # Three disjoint frame pairs per depth window, because the matched null
        # needs depth OVERLAP between pairs that share no frame -- a session
        # that never revisited a distance would have no partner to draw and no
        # null at all. That is a real property of the estimand and not a
        # fixture convenience.
        rng = np.random.default_rng(12)
        rows = []
        index = 0
        for base in np.linspace(0.6, 4.6, 5):
            for _ in range(3):
                source = index * 10
                index += 1
                for _ in range(500):
                    depth = float(rng.uniform(base, base + 0.04))
                    residual = float(rng.normal(0.0, 0.002 + 0.02 * depth))
                    x = int(rng.integers(0, 256))
                    y = int(rng.integers(0, 192))
                    rows.append((
                        1, 0.0333, 2, round(depth, 6), round(residual, 9),
                        source, source + 1, x, y, x, y, 0.01, 0.01,
                    ))
        with tempfile.TemporaryDirectory() as directory:
            observations = span.read_geometry(written(rows, directory))
        found = ratios(observations)
        self.assertTrue(found)
        np.testing.assert_allclose(found, np.ones(len(found)), atol=0.15)

    def test_target_pixel_collisions_are_rejected_and_counted(self):
        # Two source pixels rounding to one target pixel share the `observed`
        # depth both residuals are measured from. Left in, they would be a
        # perfectly cancelling pair with no pose in it.
        rng = np.random.default_rng(13)
        rows = planted_rows(rng, pairs=2, per_pair=200, common=0.0, independent=0.01)
        # A whole group of distinct source pixels rounding onto ONE target
        # pixel, which is what happens where the reprojection compresses. Two
        # planted rows would leave the count to chance; forty make it certain,
        # and the point of the test is the rejection rather than the draw.
        collided = [
            (1, 0.0333, 2, 1.1, round(float(rng.normal(0, 0.01)), 9),
             0, 1, 5 + index, 5, 77, 88, 0.0, 0.0)
            for index in range(40)
        ]
        with tempfile.TemporaryDirectory() as directory:
            observations = span.read_geometry(written(rows + collided, directory))
        result = span.cell_ratios(observations, 2)
        self.assertGreater(result["targetPixelCollisions"], 0)

    def test_the_null_never_pairs_two_residuals_from_one_frame_pair(self):
        # Structural rather than statistical, because a statistical version of
        # this does not bite: with many frame pairs, a null that leaks
        # same-pair partners moves the median too little to fail anything.
        #
        # So the fixture makes the leak arithmetically visible. Every row of
        # pair A carries residual 0 and every row of pair B carries 1, at one
        # depth so the matching never rejects. A legitimate cross-pair
        # difference is therefore ALWAYS exactly 1; a leaked same-pair
        # difference is always exactly 0. One zero in the output is the bug.
        rows = []
        for source, residual in ((0, 0.0), (10, 1.0)):
            rows += [
                (1, 0.0333, 2, 1.1, residual, source, source + 1, x, 5, x, 5, 0.0, 0.0)
                for x in range(200)
            ]
        with tempfile.TemporaryDirectory() as directory:
            observations = span.read_geometry(written(rows, directory))
        drawn = span.permuted_samples(
            observations, 2, np.random.default_rng(0), draws=20_000
        )
        self.assertGreater(drawn.size, 0)
        np.testing.assert_array_equal(drawn, np.ones(drawn.size))

    def test_the_null_rejects_a_partner_that_merely_shares_one_frame(self):
        # At k=1 adjacent pairs share a frame, so "a different pair" is not
        # enough. Pairs 0-1 and 1-2 share frame 1: every cross draw between
        # them must be rejected, leaving nothing at all.
        rows = []
        for source, residual in ((0, 0.0), (1, 1.0)):
            rows += [
                (1, 0.0333, 2, 1.1, residual, source, source + 1, x, 5, x, 5, 0.0, 0.0)
                for x in range(200)
            ]
        with tempfile.TemporaryDirectory() as directory:
            observations = span.read_geometry(written(rows, directory))
        drawn = span.permuted_samples(
            observations, 2, np.random.default_rng(0), draws=20_000
        )
        self.assertEqual(drawn.size, 0)


    def test_the_statistics_own_null_never_uses_a_partner_sharing_a_frame(self):
        # The two tests above exercise `permuted_samples`, which the statistic
        # does NOT use -- and breaking the guard on the path that feeds
        # `cell_ratios` left them green. So this asserts on that path, and it
        # asserts two things rather than one: that no shared-frame partner was
        # USED, and that some were REJECTED. Without the second, the first
        # passes vacuously on any fixture where sharing never came up, which is
        # exactly how a guard goes untested while looking tested.
        rng = np.random.default_rng(17)
        rows = []
        for source in (0, 10, 20):
            rows += [
                (1, 0.0333, 2, round(float(rng.uniform(1.0, 1.02)), 6),
                 round(float(rng.normal(0, 0.01)), 9),
                 source, source + 1,
                 int(rng.integers(0, 256)), int(rng.integers(0, 192)),
                 int(rng.integers(0, 256)), int(rng.integers(0, 192)),
                 0.0, 0.0)
                for _ in range(400)
            ]
        with tempfile.TemporaryDirectory() as directory:
            observations = span.read_geometry(written(rows, directory))
        result = span.cell_ratios(observations, 2)
        self.assertEqual(result["sharedFrameLeaked"], 0)
        self.assertGreater(result["sharedFrameRejected"], 0)


    def test_the_null_is_matched_per_cell_and_not_pooled(self):
        # The estimand's text says each null draw inherits the separation band
        # of the same-pair draw it answers. Nothing else in this suite compares
        # that sentence to the code, so this does -- structurally rather than
        # by matching words.
        #
        # Two invariants, and the pooled design violates both: a null draw
        # exists only where a same-pair draw did, so no cell can hold more null
        # draws than same-pair draws; and every null separation is one of the
        # same-pair separations rather than a value of its own. A null pooled
        # over the class would put its whole population into every cell.
        rng = np.random.default_rng(18)
        rows = planted_rows(rng, pairs=6, per_pair=300, common=0.05, independent=0.01)
        with tempfile.TemporaryDirectory() as directory:
            observations = span.read_geometry(written(rows, directory))
        drawn, *_ = span.same_pair_samples(
            observations, 2, np.random.default_rng(span.SEED)
        )
        self.assertGreater(drawn["null"].size, 0)
        self.assertEqual(drawn["null"].size, drawn["nullSeparation"].size)
        self.assertLessEqual(drawn["nullSeparation"].size, drawn["separation"].size)
        self.assertTrue(
            np.isin(drawn["nullSeparation"], drawn["separation"]).all(),
            "a null draw carried a separation no same-pair draw had",
        )
        for cell in span.cell_ratios(observations, 2)["cells"]:
            with self.subTest(band=(cell["low"], cell["high"])):
                self.assertLessEqual(cell["nullPairs"], cell["pairs"])


class TheLateralIsCensoredByItsOwnFilter(unittest.TestCase):
    """The forward-backward radius is a gate, so every surviving displacement
    is inside it by construction and every statistic of the survivors is biased
    low. These tests are about that bias, not around it."""

    RADIUS = 1.0

    def rows_with_displacement(self, rng, scale, count=600):
        rows = []
        for index in range(count):
            while True:
                dx, dy = rng.normal(0.0, scale, 2)
                # The filter, applied exactly as the analysis applies it: a
                # sample outside the radius never reaches the export at all.
                if dx * dx + dy * dy <= self.RADIUS * self.RADIUS:
                    break
            rows.append((
                1, 0.0333, 2, 1.1, 0.004, 0, 1,
                index % 256, 5, index % 256, 5, round(float(dx), 6), round(float(dy), 6),
            ))
        return rows

    def summary_for(self, scale, seed):
        rng = np.random.default_rng(seed)
        with tempfile.TemporaryDirectory() as directory:
            observations = span.read_geometry(
                written(self.rows_with_displacement(rng, scale), directory)
            )
        return span.lateral_summary(observations, 2, self.RADIUS)

    def test_a_bound_that_does_not_bind_leaves_the_median_clear_of_it(self):
        # Displacements far inside the radius: the filter removed almost
        # nothing, so the median describes the sensor.
        summary = self.summary_for(scale=0.05, seed=20)
        self.assertLess(summary["medianPixels"], 0.5 * self.RADIUS)
        self.assertGreater(summary["clearance"], 0.5)
        self.assertLess(summary["atBound"], 0.01)
        self.assertEqual(
            span.lateral_verdict(summary, clearance_margin=span.LATERAL_CLEARANCE_MARGIN),
            span.LATERAL_REPORTABLE,
        )

    def test_a_binding_bound_lands_on_the_derived_censored_floor(self):
        # Displacements whose true scale is far OUTSIDE the radius: the filter
        # keeps only what fits, so the survivors are uniform over the disk in
        # the limit and the median radius is R/sqrt(2). The clearance therefore
        # does NOT go to zero -- it bottoms out at 1 - 1/sqrt(2).
        #
        # That is the whole reason the floor is registered. The number still
        # looks perfectly ordinary, which is the danger, and a margin chosen
        # below the floor would call this reportable.
        summary = self.summary_for(scale=5.0, seed=21)
        self.assertGreater(summary["atBound"], 0.10)
        self.assertAlmostEqual(
            summary["clearance"], span.LATERAL_CLEARANCE_FLOOR, delta=0.03
        )
        self.assertEqual(
            span.lateral_verdict(summary, clearance_margin=span.LATERAL_CLEARANCE_MARGIN),
            span.LATERAL_REFUSED,
        )

    def test_a_margin_at_or_below_the_censored_floor_is_itself_refused(self):
        # A threshold with no power is not a threshold. Registering one below
        # the floor would pass a fully filter-shaped distribution, so the
        # constant is refused rather than the data.
        summary = self.summary_for(scale=5.0, seed=25)
        for margin in (0.10, span.LATERAL_CLEARANCE_FLOOR):
            with self.subTest(margin=margin):
                with self.assertRaises(ValueError):
                    span.lateral_verdict(summary, clearance_margin=margin)

    def test_the_radius_always_rides_beside_the_median(self):
        # The number is never reportable alone. Both outcomes carry the bound.
        for scale, seed in ((0.05, 22), (5.0, 23)):
            with self.subTest(scale=scale):
                summary = self.summary_for(scale, seed)
                self.assertEqual(summary["truncationRadiusPixels"], self.RADIUS)
                self.assertIsNotNone(summary["atBound"])

    def test_an_unregistered_clearance_raises_rather_than_answering(self):
        # As above: the threshold is filled, so this pins what an unset one
        # does rather than observing that it is unset.
        with self.assertRaises(ValueError):
            span._registered_clearance(None)

    def test_the_registered_clearance_decides_both_fixtures(self):
        # The verdicts under the value actually registered, rather than under
        # an argument passed in for the occasion.
        self.assertEqual(
            span.lateral_verdict(self.summary_for(scale=0.05, seed=24)),
            span.LATERAL_REPORTABLE,
        )
        self.assertEqual(
            span.lateral_verdict(self.summary_for(scale=5.0, seed=26)),
            span.LATERAL_REFUSED,
        )


class TheSeedIsRegistered(unittest.TestCase):
    def test_the_statistic_is_reported_at_every_registered_seed(self):
        rng = np.random.default_rng(15)
        rows = planted_rows(rng, common=0.10, independent=0.01)
        with tempfile.TemporaryDirectory() as directory:
            observations = span.read_geometry(written(rows, directory))
        stability = span.seed_stability(observations, 2)
        self.assertEqual(sorted(stability), sorted(str(s) for s in span.SEED_STABILITY_SEEDS))
        # Randomness entered a measured path here for the first time, so this
        # is reported rather than assumed: the planted signal is far from the
        # threshold, and every seed must agree it cancels.
        for seed, values in stability.items():
            with self.subTest(seed=seed):
                found = [value for value in values if value is not None]
                self.assertTrue(found)
                self.assertLess(max(found), 0.5)

    def test_one_seed_reproduces_exactly(self):
        rng = np.random.default_rng(16)
        rows = planted_rows(rng, pairs=4, per_pair=400)
        with tempfile.TemporaryDirectory() as directory:
            observations = span.read_geometry(written(rows, directory))
        first = span.cell_ratios(observations, 2, seed=7)
        second = span.cell_ratios(observations, 2, seed=7)
        self.assertEqual(first, second)


class TheSharpnessConditionIsRegistered(unittest.TestCase):
    """Reading (b), DEVLOG 2026-08-14: the margin is fixed first and the
    null's own replicate spread is checked afterward as a validity condition,
    never used to choose the margin. Replicate means SEED here -- the
    registered seed IS the replicate axis (`SEED_STABILITY_SEEDS`), not the
    four containers, which are a different population each and already
    guarded by unanimity."""

    def test_the_verdict_reads_the_registered_margin(self):
        # Hand-built spreads, the same style as the cancellation boundary's
        # own test: the arithmetic is what is under test, not a fixture's
        # capacity to produce a large spread.
        self.assertEqual(span.sharpness_verdict(0.02), span.SHARPNESS_CLEARED)
        self.assertEqual(span.sharpness_verdict(0.099), span.SHARPNESS_CLEARED)
        # At the margin exactly: "not smaller than" refuses the boundary.
        self.assertEqual(span.sharpness_verdict(0.10), span.SHARPNESS_REFUSED)
        self.assertEqual(span.sharpness_verdict(0.15), span.SHARPNESS_REFUSED)
        self.assertEqual(span.sharpness_verdict(None), span.INSUFFICIENT_PAIRS)

    def test_a_thin_cell_reads_insufficient_rather_than_a_spread(self):
        # Fewer than MINIMUM_CELL_PAIRS survive in most bands here, so
        # `permuted` is None at one or more of the three seeds and the spread
        # must not be computed over a list holding None.
        rng = np.random.default_rng(40)
        rows = planted_rows(rng, pairs=2, per_pair=60, common=0.02, independent=0.01)
        with tempfile.TemporaryDirectory() as directory:
            observations = span.read_geometry(written(rows, directory))
        spreads = span.sharpness_spread(observations, 2)
        self.assertTrue(any(spread is None for spread in spreads))
        for spread in spreads:
            if spread is None:
                self.assertEqual(span.sharpness_verdict(spread), span.INSUFFICIENT_PAIRS)

    def test_the_spread_is_computed_from_permuted_not_ratio(self):
        # Distinct from `seed_stability`, which varies with the RATIO:
        # this is hand-verified against `cell_ratios`' own `permuted` field,
        # the null's denominator, at each registered seed.
        rng = np.random.default_rng(41)
        rows = planted_rows(rng, pairs=10, per_pair=1000, common=0.02, independent=0.01)
        with tempfile.TemporaryDirectory() as directory:
            observations = span.read_geometry(written(rows, directory))
        spreads = span.sharpness_spread(observations, 2)
        per_seed = [
            span.cell_ratios(observations, 2, seed=seed)["cells"]
            for seed in span.SEED_STABILITY_SEEDS
        ]
        for band_index, spread in enumerate(spreads):
            values = [cells[band_index]["permuted"] for cells in per_seed]
            with self.subTest(band=band_index):
                if any(value is None for value in values):
                    self.assertIsNone(spread)
                else:
                    mean = sum(values) / len(values)
                    expected = None if mean == 0 else (max(values) - min(values)) / mean
                    self.assertEqual(spread, expected)

    def test_well_populated_cells_clear_the_margin_on_this_fixture(self):
        # Measured, not assumed: with PAIRS_PER_CELL = 20_000 the upper
        # median is pinned tightly, so on data with no pathology the spread
        # stays a small fraction of CANCELLATION_MARGIN. Recorded in DEVLOG
        # alongside this commit -- observed spreads ran roughly 0.003-0.04
        # against a fixed seed at thousands of pairs per band, an order of
        # magnitude below the 0.10 margin. This pins that finding as a
        # regression rather than letting it silently drift.
        rng = np.random.default_rng(103)
        rows = planted_rows(rng, pairs=20, per_pair=4000, common=0.02, independent=0.01)
        with tempfile.TemporaryDirectory() as directory:
            observations = span.read_geometry(written(rows, directory))
        spreads = span.sharpness_spread(observations, 2)
        measured = [spread for spread in spreads if spread is not None]
        self.assertTrue(measured)
        for spread in measured:
            self.assertLess(spread, 0.5 * span.CANCELLATION_MARGIN)


class TheArtifact(unittest.TestCase):
    def built(self, seed=30):
        rng = np.random.default_rng(seed)
        rows = planted_rows(rng, pairs=6, per_pair=300, common=0.05, independent=0.01)
        with tempfile.TemporaryDirectory() as directory:
            observations = span.read_geometry(written(rows, directory))
        result = span.cell_ratios(observations, 2)
        lateral = span.lateral_summary(observations, 2, 1.0)
        provenance = [{"session": "PLANTED-TEST", "pairStride": 8, "pairsKept": 6}]
        return observations, span.build_artifact({2: result}, {2: lateral}, provenance, 1.0)

    def test_round_trip_and_schema_rejection(self):
        _, artifact = self.built()
        self.assertEqual(artifact["schema"], span.ARTIFACT_SCHEMA)
        self.assertEqual(artifact["estimand"], span.ESTIMAND)
        self.assertEqual(artifact["spanInterval"], "refused")
        self.assertTrue(artifact["spanIntervalReason"])
        with tempfile.TemporaryDirectory() as directory:
            path = os.path.join(directory, "span.json")
            span.write_artifact(path, artifact)
            self.assertEqual(span.read_artifact(path), json.loads(json.dumps(artifact)))
            wrong = os.path.join(directory, "other.json")
            with open(wrong, "w", encoding="utf-8") as handle:
                json.dump({"schema": "something-else/9"}, handle)
            with self.assertRaises(ValueError):
                span.read_artifact(wrong)

    def test_no_per_row_value_survives_into_the_artifact(self):
        # The privacy decision, enforced rather than promised. The `/2` rows
        # are per-pixel and stay local; this asserts that none of them -- and
        # no extremum, because an extremum IS a row -- reaches the file that
        # does enter the repository.
        observations, artifact = self.built()
        with tempfile.TemporaryDirectory() as directory:
            path = os.path.join(directory, "span.json")
            span.write_artifact(path, artifact)
            with open(path, encoding="utf-8") as handle:
                text = handle.read()

        # No geometry column name is even mentioned.
        for name in ("src_frame", "tgt_frame", "src_x", "src_y", "tgt_x", "tgt_y"):
            with self.subTest(column=name):
                self.assertNotIn(name, text)

        # And no row's actual values appear. Frame indices and pixels are
        # small integers that could collide with a count by coincidence, so
        # this checks the values that could not: the residuals and depths,
        # which are the reconstructable part.
        numbers = set()
        for token in text.replace(",", " ").replace(":", " ").split():
            try:
                numbers.add(round(float(token.strip('"[]{}')), 9))
            except ValueError:
                continue
        for column in ("delta", "depth", "rt_dx", "rt_dy"):
            values = {round(float(v), 9) for v in observations[column]}
            with self.subTest(column=column):
                self.assertFalse(
                    values & numbers,
                    f"a per-row {column} value reached the artifact",
                )

    def test_the_artifact_carries_the_rule_and_its_axial_limit(self):
        _, artifact = self.built()
        self.assertEqual(artifact["component"], "axial")
        self.assertIn("Cov", artifact["propagationRule"])
        self.assertIn("axial", artifact["propagationRule"].lower())
        self.assertEqual(artifact["lateralUnits"], "depth pixels")
        self.assertAlmostEqual(
            artifact["lateralClearanceFloor"], 1.0 - 1.0 / np.sqrt(2.0)
        )


class TheCommandLine(unittest.TestCase):
    """Two kinds of refusal, not one. File-level `ValueError`s are structural
    -- the CLI exits non-zero with the registered message. Per-cell and
    per-lateral verdicts are ordinary outcomes on real data -- reported, and
    the process exits zero -- so a thin band in an otherwise healthy session
    never fails the whole run."""

    def run_cli(self, args):
        out, err = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            code = span.main(["span.py"] + args)
        return code, out.getvalue(), err.getvalue()

    def output_dir(self, directory):
        path = os.path.join(directory, "out")
        os.makedirs(path)
        return path

    def test_a_v1_file_exits_non_zero(self):
        with tempfile.TemporaryDirectory() as directory:
            path = os.path.join(directory, "observations.csv")
            with open(path, "w", encoding="utf-8") as handle:
                handle.write(
                    "# skewline-observations/1\n"
                    "# session S\n"
                    "# columns k,delta_t,class,depth,delta\n"
                    "1,0.0333,2,1.25,0.004\n"
                )
            code, _, err = self.run_cli(["--output-dir", self.output_dir(directory), path])
        self.assertEqual(code, 1)
        self.assertIn("skewline-observations/2", err)

    def test_a_sampling_header_that_is_not_pair_stride_exits_non_zero(self):
        rows = planted_rows(np.random.default_rng(50), pairs=2, per_pair=8)
        with tempfile.TemporaryDirectory() as directory:
            path = written(rows, directory, sampling="every-nth")
            code, _, err = self.run_cli(["--output-dir", self.output_dir(directory), path])
        self.assertEqual(code, 1)
        self.assertIn("pair-stride", err)

    def test_a_session_with_no_disjoint_pair_exits_non_zero(self):
        rows = [
            (1, 0.0333, 2, 1.0, 0.001, 0, 1, 10, 10, 10, 10, 0.0, 0.0),
            (1, 0.0333, 2, 1.0, 0.001, 0, 2, 10, 10, 10, 10, 0.0, 0.0),
        ]
        with tempfile.TemporaryDirectory() as directory:
            path = written(rows, directory)
            code, _, err = self.run_cli(["--output-dir", self.output_dir(directory), path])
        self.assertEqual(code, 1)
        self.assertIn("no frame", err)

    def test_a_row_whose_frame_has_no_intrinsics_exits_non_zero(self):
        # Two disjoint pairs, but intrinsics supplied for only one source
        # frame -- distinct from the file-level "no intrinsics header" case,
        # which `read_geometry` already refuses on its own.
        rows = planted_rows(np.random.default_rng(51), pairs=2, per_pair=50)
        with tempfile.TemporaryDirectory() as directory:
            path = written(rows, directory, frames=[0])
            code, _, err = self.run_cli(["--output-dir", self.output_dir(directory), path])
        self.assertEqual(code, 1)
        self.assertIn("no intrinsics", err)

    def test_a_missing_radius_header_exits_non_zero(self):
        rows = planted_rows(np.random.default_rng(52), pairs=2, per_pair=8)
        text = geometry_text(rows)
        text = "\n".join(
            line for line in text.splitlines()
            if not line.startswith("# forward-backward-radius")
        ) + "\n"
        with tempfile.TemporaryDirectory() as directory:
            path = os.path.join(directory, "geometry.csv")
            with open(path, "w", encoding="utf-8") as handle:
                handle.write(text)
            code, _, err = self.run_cli(["--output-dir", self.output_dir(directory), path])
        self.assertEqual(code, 1)
        self.assertIn("forward-backward-radius", err)

    def test_a_thin_cell_reports_insufficient_and_exits_zero(self):
        # The property the two kinds of refusal must not conflate: a real
        # session with one sparse band must not fail the whole run.
        rows = planted_rows(np.random.default_rng(53), pairs=2, per_pair=8)
        with tempfile.TemporaryDirectory() as directory:
            path = written(rows, directory)
            code, out, _ = self.run_cli(["--output-dir", self.output_dir(directory), path])
        self.assertEqual(code, 0)
        self.assertIn(span.INSUFFICIENT_PAIRS, out)

    def test_the_report_prints_per_container_values_not_an_aggregate(self):
        # Two containers with deliberately different cancellation strength,
        # so a pooled mean would produce a THIRD number neither of these is
        # -- and the report must show both of theirs, not it.
        rows_one = planted_rows(
            np.random.default_rng(60), pairs=10, per_pair=1000, common=0.02, independent=0.01
        )
        rows_two = planted_rows(
            np.random.default_rng(61), pairs=10, per_pair=1000, common=0.08, independent=0.01
        )
        with tempfile.TemporaryDirectory() as first, \
                tempfile.TemporaryDirectory() as second, \
                tempfile.TemporaryDirectory() as combined:
            path_one = written(rows_one, first, session="CONTAINER-ONE")
            path_two = written(rows_two, second, session="CONTAINER-TWO")
            ratio_one = span.cell_ratios(span.read_geometry(path_one), 2)["cells"][3]["ratio"]
            ratio_two = span.cell_ratios(span.read_geometry(path_two), 2)["cells"][3]["ratio"]
            out_dir = self.output_dir(combined)
            code, out, _ = self.run_cli(["--output-dir", out_dir, path_one, path_two])
            artifacts = sorted(os.listdir(out_dir))
        self.assertEqual(code, 0)
        self.assertEqual(artifacts, ["CONTAINER-ONE.span.json", "CONTAINER-TWO.span.json"])
        self.assertIsNotNone(ratio_one)
        self.assertIsNotNone(ratio_two)
        self.assertNotAlmostEqual(ratio_one, ratio_two, places=3)
        self.assertIn(f"{ratio_one:.6f}", out)
        self.assertIn(f"{ratio_two:.6f}", out)


if __name__ == "__main__":
    unittest.main()
