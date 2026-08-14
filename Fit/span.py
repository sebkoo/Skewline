"""Whether two points' errors cancel, and by how much.

This module answers one question the fit could not: given two points seen in
the SAME frame pair, is the disagreement of their difference smaller than the
disagreement of either endpoint? Pose error is common-mode across two points in
one pair and should largely cancel in a difference, so a span may be more
accurate than the naive rule predicts. It may also not be, and refusal is a
finding.

THE RULE, DERIVED, AND AXIAL ONLY.

    Var(r_b - r_a) = Var(r_a) + Var(r_b) - 2 * Cov(r_a, r_b)

The naive rule is Cov = 0, which gives sigma * sqrt(2) -- the tape-measure
number v0.9 refused. The whole content of this module is the third term. `r` is
the signed AXIAL depth residual: observed minus predicted planar z along the
TARGET camera's optical axis. It is one diagonal element of a point's error
covariance, so this is a propagation rule for the axial component of a
separation and NOT for a separation.

THE NULL IS A PERMUTATION, NOT sqrt(2).

Quoting sqrt(2) assumes a relation between the median of a difference and the
median of one reading -- a distributional claim, and the very hypothesis under
test. Instead the partner `b` is replaced by a residual from a frame pair
SHARING NO FRAME, matched on class and fine depth. That leaves both marginals
where they were and forces Cov to zero by construction, because two disjoint
frame pairs share no sample. The permuted spread is therefore the naive rule's
own prediction computed on this data, and the ratio is 1 under independence BY
CONSTRUCTION. Cancellation is ratio < 1.

THE NULL IS MATCHED PER CELL, NOT FLAT. A permuted partner has no separation of
its own -- separation is a property of a pair, not of a point -- which invites
pooling the null into one number per class and reading the signal off a
same-pair curve rising toward it. That design was registered first and is
WRONG, and a planted synthetic population proved it before any container was
exported: separation is `(pixel offset) * depth / focal length`, so a
small-separation cell is populated by NEAR points, whose residuals are smaller
because |delta| grows with depth. A pooled null sits above those cells for a
reason unrelated to cancellation, and on data with no pair structure at all it
read ratios near 0.4 -- a false positive, strongest exactly where the real
effect is predicted.

So each null draw rides beside the same-pair draw it answers and inherits that
draw's separation band. Numerator and denominator then share a depth
composition by construction, and the comparison is within-cell.

WHAT A CANCELLATION LOOKS LIKE NOW. Not "a curve rising toward a flat null" --
that reading belonged to the pooled design and would mislead. The comparison is
within each cell, so every separation dependence lives in the numerator and the
ratio carries it directly: cancellation is a ratio BELOW 1 inside a band, and
cancellation degrading with distance is that ratio RISING TOWARD 1 as the bands
widen. A ratio at 1 in every band is independence, and above 1 is
anti-correlation, which is worse than the naive rule rather than the same as no
effect.

MATCHED ON FINE DEPTH, NEVER ON BAND. |delta| grows with depth and neighbouring
pixels have nearer depths, so a band-matched partner is drawn from a wider
depth spread than the point it replaces -- inflating the null, deflating the
ratio, and manufacturing cancellation out of a scale mismatch. That is the
difference between measuring the effect and inventing it.

WHAT IS NOT CLAIMED. No standard error, no p-value, no confidence interval.
Observations are heavily correlated across neighbouring pixels and frames --
v0.6 refused i.i.d. standard errors for exactly this -- and here it is worse in
two ways: a pair is built from two samples correlated with each other BY
HYPOTHESIS, which is the thing being measured, and the permutation breaks
frame-pair sharing without breaking the partner's own spatial correlation with
its neighbours. Unanimity across the four containers is the only guard, which
is why it exists.

This module reads `skewline-observations/2` files only. They derive from home
captures, carry a frame index and a pixel per row, and never enter the
repository; only the aggregate artifact does.
"""

import json
import math

import numpy as np

import fit

# --- Registered constants -------------------------------------------------

SCHEMA_TAG = fit.GEOMETRY_SCHEMA_TAG
ARTIFACT_SCHEMA = "skewline-span/1"

# The sampling rule this analysis requires. A file decimated by v0.6's
# every-Nth rule cannot answer the question: that comb is periodic in survivor
# index, so retained separations alias against the covariate and the small ones
# are structurally absent. Refused rather than read.
REQUIRED_SAMPLING = "pair-stride"

# The registered separation, unchanged from v0.6: the fit's own data.
SEPARATION_K = 1

CLASS_NAMES = fit.CLASS_NAMES

ESTIMAND = (
    "within each lateral separation band, the ratio of the upper median "
    "|r_b - r_a| for two same-class source pixels sharing one (source, target) "
    "frame pair at k=1 under the registered filter chain, to the upper median "
    "of |r_a - r_b'| over those same draws with b replaced by a residual "
    "matched on class and fine depth and drawn from a frame pair sharing no "
    "frame -- each null draw inheriting the separation band of the same-pair "
    "draw it answers, so numerator and denominator share a depth composition "
    "by construction; r is the signed axial depth residual in meters -- "
    "observed minus predicted planar z along the target camera's optical axis "
    "-- the ratio dimensionless, reported per class and separation band and "
    "never pooled to one number -- not a 3-D distance error, not accuracy "
    "against any known length, not a single-reading sigma, not sigma times "
    "root two, not a correlation coefficient and not an interval"
)
UNITS = "dimensionless -- a ratio of meters to meters"
COMPONENT = "axial"
OUTSIDE_DOMAIN = "refuse"

# The lateral estimand, censored by the filter that produces it. Every
# surviving sample has round-trip displacement inside `forwardBackwardRadius`
# BY CONSTRUCTION, so the survivors' distribution is truncated from above and
# every statistic of it -- the median included -- is biased low. Reportable
# only beside its bound.
LATERAL_ESTIMAND = (
    "upper median of the forward-backward round-trip displacement of the same "
    "pairs, in depth pixels, reported only beside the truncation radius that "
    "produced it -- a measurement of the sensor only where the bound is not "
    "binding at the statistic, and of the filter otherwise"
)
LATERAL_UNITS = "depth pixels"

# The clearance a totally censored population still shows, derived rather than
# observed. If the true displacement scale is far outside the radius, the
# survivors are those that happen to land inside it -- uniform over the disk in
# the limit -- and for points uniform on a disk of radius R, P(r <= t) =
# t^2/R^2, so the median radius is R/sqrt(2) and the clearance
# (R - median)/R is 1 - 1/sqrt(2) ~ 0.293.
#
# So clearance does NOT approach zero when the bound does all the work: it
# bottoms out here. A registered margin at or below this floor would call a
# fully filter-shaped distribution "reportable", which is the exact overclaim
# the criterion exists to prevent. The margin must exceed it, and
# `_registered_clearance` refuses a value that does not.
LATERAL_CLEARANCE_FLOOR = 1.0 - 1.0 / math.sqrt(2.0)

# Lateral camera-space separation bands, in meters, half-open like BAND_EDGES
# and read by the same contract: >= first, < last, outside is no band. The
# covariate is LATERAL and not full 3-D: for a small relative-rotation error
# the induced error in the predicted depth difference is
# -(dTheta x dX)_z = -(dTheta_x * dY - dTheta_y * dX), in which dZ does not
# appear. A dZ dependence would be a multiplicative depth-scale error instead,
# which is a separable second prediction and a diagnostic rather than this
# statistic.
SEPARATION_EDGES = (0.0, 0.02, 0.05, 0.10, 0.20, 0.40, 0.80, 1.60)

# The null's depth matching, in meters. Fine, never banded -- see the module
# docstring. Half the narrowest registered depth band's width would be 0.25 m,
# which is far too coarse for a quantity that grows with depth across it.
DEPTH_MATCH_TOLERANCE = 0.05

# Pairs are quadratic in survivors per frame pair, so the pair set is sampled
# rather than enumerated. Seeded, and the seed is registered: this is the first
# randomness on a measured path in this repository -- `fit.py`'s fit path has
# none -- so a seed-stability diagnostic is reported beside the result and a
# statistic that moves with the seed is a finding.
PAIRS_PER_CELL = 20_000
MINIMUM_CELL_PAIRS = 2_000
SEED = 0
SEED_STABILITY_SEEDS = (0, 1, 2)

# Verdict vocabulary, mirroring Calibration.OrderingVerdict's shape: a silence
# must be legible as a specific silence rather than as a missing number.
CANCELS_WITH_MARGIN = "cancels with margin"
CANCELS_WITHOUT_MARGIN = "cancels without margin"
DOES_NOT_CANCEL = "does not cancel"
ANTI_CORRELATED = "anti-correlated"
INSUFFICIENT_PAIRS = "insufficient pairs"

# The lateral component's two outcomes. "Refused" is not "unavailable":
# the number exists and is not reported, because what it measures is the
# filter rather than the sensor.
LATERAL_REPORTABLE = "reportable beside its bound"
LATERAL_REFUSED = "refused -- the bound is binding at the statistic"


# --- Reading the widened export -------------------------------------------

def read_geometry(path):
    """One `/2` export, with the sampling rule checked before anything is
    believed. A `/1` file and a `/2` file sampled by the every-Nth rule are
    both refused, and for the same reason: neither can carry the covariate."""
    observations = fit.read_observations(path)
    if observations["schema"] != SCHEMA_TAG:
        raise ValueError(f"{path}: not a {SCHEMA_TAG} file")
    sampling = observations["metadata"].get("sampling")
    if sampling != REQUIRED_SAMPLING:
        raise ValueError(
            f"{path}: sampling is {sampling!r}, and this analysis requires "
            f"{REQUIRED_SAMPLING!r} -- a within-pair decimation aliases "
            f"against the separation covariate"
        )
    if not observations["intrinsics"]:
        raise ValueError(f"{path}: no intrinsics header, so no separation is computable")
    return observations


def camera_xy(observations):
    """The source points' lateral camera coordinates in meters, from the pixel,
    the depth and that frame's own intrinsics.

    Per-frame and never per-file: the smoke run recorded three different focal
    lengths across three frames of one session, so a single value would be
    wrong for most of them and every separation derived from it wrong with it.
    A row whose frame has no intrinsics line fails loudly rather than borrowing
    a neighbour's.
    """
    frames = observations["src_frame"]
    table = observations["intrinsics"]
    missing = sorted({int(f) for f in frames} - set(table))
    if missing:
        raise ValueError(f"no intrinsics for source frames {missing}")
    if frames.size == 0:
        return np.empty(0), np.empty(0)
    parameters = np.array([table[int(frame)] for frame in frames], dtype=float)
    fx, fy, cx, cy = parameters[:, 0], parameters[:, 1], parameters[:, 2], parameters[:, 3]
    depth = observations["depth"]
    return (observations["src_x"] - cx) * depth / fx, (observations["src_y"] - cy) * depth / fy


def separation_band(separation):
    """Half-open, the `Calibration.bandIndex` contract exactly: -1 for anything
    outside the outermost edges, so it is counted rather than silently
    dropped."""
    separation = np.asarray(separation, dtype=float)
    index = np.searchsorted(np.asarray(SEPARATION_EDGES), separation, side="right") - 1
    index = np.where(separation >= SEPARATION_EDGES[-1], -1, index)
    return np.where(separation < SEPARATION_EDGES[0], -1, index)


# --- The pair set ---------------------------------------------------------

def _pair_key(observations):
    """One integer per (source frame, target frame), for grouping."""
    return observations["src_frame"].astype(np.int64) * (1 << 32) + observations["tgt_frame"]


def same_pair_samples(observations, class_index, rng, pairs_per_cell=PAIRS_PER_CELL):
    """Draws pairs of surviving pixels from within one frame pair.

    The registered pair filters, each applied here and counted by the caller:
    distinct source pixels; same confidence class; same (source, target) frame
    pair; and DISTINCT TARGET PIXELS -- two source pixels can round to one
    target pixel and then literally share the `observed` depth both residuals
    are measured from, a coincidence that concentrates at small separation and
    would manufacture agreement out of arithmetic.

    Each same-pair draw is answered by ONE null draw that keeps `a` and
    replaces `b` with a depth-matched residual from a frame pair sharing no
    frame. Building the null per draw rather than pooling it is not a
    refinement -- see `cell_ratios`.

    Returns a dict of parallel arrays plus the rejection counts.
    """
    selected = (observations["k"] == SEPARATION_K) & (observations["class"] == class_index)
    empty = {
        "separation": np.empty(0), "same": np.empty(0),
        "null": np.empty(0), "nullSeparation": np.empty(0),
    }
    if not selected.any():
        return empty, 0, 0, 0, 0
    x, y = camera_xy(observations)
    delta = observations["delta"][selected]
    depth = observations["depth"][selected]
    x, y = x[selected], y[selected]
    target_x = observations["tgt_x"][selected]
    target_y = observations["tgt_y"][selected]
    source = observations["src_frame"][selected]
    target = observations["tgt_frame"][selected]
    keys = _pair_key(observations)[selected]

    # One depth ordering for the whole class, so a partner window is a
    # contiguous range rather than a scan.
    order = np.argsort(depth, kind="stable")
    depth_sorted = depth[order]

    separations, differences = [], []
    null_values, null_separations = [], []
    collisions, unmatched = 0, 0
    shared_rejected, shared_leaked = 0, 0
    for key in np.unique(keys):
        inside = np.flatnonzero(keys == key)
        if inside.size < 2:
            continue
        draws = min(pairs_per_cell, inside.size * (inside.size - 1) // 2)
        if draws == 0:
            continue
        first = rng.choice(inside, size=draws)
        second = rng.choice(inside, size=draws)
        distinct = first != second
        collision = (target_x[first] == target_x[second]) & (target_y[first] == target_y[second])
        collisions += int(np.count_nonzero(distinct & collision))
        keep = distinct & ~collision
        first, second = first[keep], second[keep]
        if first.size == 0:
            continue
        separation = np.hypot(x[first] - x[second], y[first] - y[second])
        separations.append(separation)
        differences.append(np.abs(delta[first] - delta[second]))

        partner = _replace_partner(order, depth_sorted, depth[second], rng, DEPTH_MATCH_TOLERANCE)
        shares = (
            (source[first] == source[partner]) | (source[first] == target[partner])
            | (target[first] == source[partner]) | (target[first] == target[partner])
        )
        usable = (partner >= 0) & ~shares
        unmatched += int(np.count_nonzero(partner < 0))
        # Two counters rather than one, so the guard's behaviour is observable
        # from the outside. `rejected` says the fixture could have leaked;
        # `leaked` must be zero, and a test that asserts only the zero would
        # pass vacuously on data where sharing never arose.
        shared_rejected += int(np.count_nonzero((partner >= 0) & shares))
        shared_leaked += int(np.count_nonzero(usable & shares))
        null_values.append(np.abs(delta[first[usable]] - delta[partner[usable]]))
        null_separations.append(separation[usable])
    if not separations:
        return empty, collisions, unmatched, shared_rejected, shared_leaked
    return {
        "separation": np.concatenate(separations),
        "same": np.concatenate(differences),
        "null": np.concatenate(null_values),
        "nullSeparation": np.concatenate(null_separations),
    }, collisions, unmatched, shared_rejected, shared_leaked


def permuted_samples(
    observations, class_index, rng, draws, tolerance=DEPTH_MATCH_TOLERANCE
):
    """A free-standing null, kept for the refusal tests: `a` keeps its
    residual and `b` is replaced by one from a frame pair SHARING NO FRAME,
    matched on fine depth.

    Sharing no frame rather than merely being a different pair: at k=1 adjacent
    pairs share a frame, so "a different pair" can still mean the same camera,
    the same pose error and the same depth map.

    This is **not** the null the statistic uses. Pooling a null over all depths
    and comparing it against cells that are implicitly depth-stratified is the
    error `_replace_partner` below exists to avoid -- see `cell_ratios`.
    """
    selected = (observations["k"] == SEPARATION_K) & (observations["class"] == class_index)
    if not selected.any() or draws <= 0:
        return np.empty(0)
    delta = observations["delta"][selected]
    depth = observations["depth"][selected]
    source = observations["src_frame"][selected]
    target = observations["tgt_frame"][selected]
    if delta.size < 2:
        return np.empty(0)

    first = rng.choice(delta.size, size=draws)
    second = rng.choice(delta.size, size=draws)
    shares_frame = (
        (source[first] == source[second])
        | (source[first] == target[second])
        | (target[first] == source[second])
        | (target[first] == target[second])
    )
    matched = np.abs(depth[first] - depth[second]) <= tolerance
    keep = matched & ~shares_frame
    return np.abs(delta[first[keep]] - delta[second[keep]])


def _replace_partner(order, depth_sorted, depth_of_b, rng, tolerance):
    """For each `b`, one candidate partner drawn uniformly from the rows whose
    depth is within `tolerance` of it. Returns indices into the class arrays,
    and -1 where the window is empty."""
    low = np.searchsorted(depth_sorted, depth_of_b - tolerance, side="left")
    high = np.searchsorted(depth_sorted, depth_of_b + tolerance, side="right")
    width = high - low
    picked = np.where(
        width > 0,
        low + (rng.random(width.size) * np.maximum(width, 1)).astype(np.int64),
        0,
    )
    picked = np.minimum(picked, np.maximum(high - 1, 0))
    return np.where(width > 0, order[picked], -1)


# --- The registered thresholds, deliberately unfilled ----------------------

# TODO(owner): both values, and P beside them, are filled in one commit BEFORE
# the first container is exported -- not merely before a commit lands. A
# criterion with an open threshold is not registered, and the hole is exactly
# where the data would walk in. They are `None` rather than a plausible number
# so that asking for a verdict now RAISES instead of quietly answering.
#
# Neither has a distribution-free derivation. Deriving one needs a claim about
# the shape of a distribution near a bound, which is the assumption this module
# refuses everywhere else, so both are judgments and are labelled as judgments
# rather than dressed as derivations.
#
# Filled 2026-08-14, before any container was exported. That ordering IS the
# registration.
#
# A ratio must sit below 1 by this much to count as cancellation, so the
# verdict boundary is ratio < 0.90. Chosen comfortably above the observed
# fixture noise floor of roughly +/-0.03 -- about three times it -- and that
# floor is a spread of planted-fixture readings, not a standard error: this
# module claims no standard error, no p-value and no interval, for the reason
# its docstring gives.
CANCELLATION_MARGIN = 0.10

# Above the analytically derived fully censored floor of 1 - 1/sqrt(2) ~= 0.2929
# that `_registered_clearance` enforces. In pixels, against the registered
# radius of 1.0: the round-trip median must sit below 0.50, where a fully
# censored population reads 0.7071.
LATERAL_CLEARANCE_MARGIN = 0.50


def _registered_clearance(value):
    """The clearance margin, with the one constraint that IS derivable: it must
    exceed the floor a totally censored population already shows, or it has no
    power to refuse one."""
    margin = _registered(value, "LATERAL_CLEARANCE_MARGIN")
    if margin <= LATERAL_CLEARANCE_FLOOR:
        raise ValueError(
            f"LATERAL_CLEARANCE_MARGIN {margin} is at or below the censored "
            f"floor {LATERAL_CLEARANCE_FLOOR:.4f}; a fully filter-shaped "
            f"distribution would clear it"
        )
    return margin


def _registered(value, name):
    if value is None:
        raise ValueError(
            f"{name} is not registered yet; it is filled before the first "
            f"export, and a verdict asked for before then would be a threshold "
            f"chosen with the data in view"
        )
    return float(value)


# --- The statistic --------------------------------------------------------

def cell_ratios(observations, class_index, seed=SEED, pairs_per_cell=PAIRS_PER_CELL):
    """One cell per lateral separation band: the same-frame-pair upper median
    of |r_b - r_a|, the null's upper median over the SAME cell, and the ratio.

    The null is binned by its draw's separation and not pooled across the
    class, and that is the correction the planted fixtures forced. A permuted
    partner genuinely has no separation of its own -- separation is a property
    of a pair, not of a point -- which invites pooling the null into one
    number. But separation is `(pixel offset) * depth / focal length`, so a
    small-separation cell is populated by NEAR points, whose residuals are
    smaller because |delta| grows with depth. A null pooled over every depth
    would then sit above those cells for a reason that has nothing to do with
    cancellation, and would read as cancellation exactly where the effect is
    predicted. Keeping each null draw beside the same-pair draw it answers
    makes the two share a depth composition by construction.
    """
    rng = np.random.default_rng(seed)
    drawn, collisions, unmatched, shared_rejected, shared_leaked = same_pair_samples(
        observations, class_index, rng, pairs_per_cell=pairs_per_cell
    )
    bands = separation_band(drawn["separation"])
    null_bands = separation_band(drawn["nullSeparation"])
    cells = []
    for index in range(len(SEPARATION_EDGES) - 1):
        inside = bands == index
        null_inside = null_bands == index
        pairs = int(np.count_nonzero(inside))
        null_pairs = int(np.count_nonzero(null_inside))
        same = fit.upper_median(drawn["same"][inside]) if pairs >= MINIMUM_CELL_PAIRS else None
        null = (
            fit.upper_median(drawn["null"][null_inside])
            if null_pairs >= MINIMUM_CELL_PAIRS else None
        )
        cells.append({
            "low": SEPARATION_EDGES[index],
            "high": SEPARATION_EDGES[index + 1],
            "pairs": pairs,
            "nullPairs": null_pairs,
            "sameFramePair": same,
            "permuted": null,
            "ratio": (same / null) if (same is not None and null) else None,
        })
    return {
        "class": CLASS_NAMES[class_index],
        "cells": cells,
        "targetPixelCollisions": collisions,
        "unmatchedPartners": unmatched,
        "sharedFrameRejected": shared_rejected,
        "sharedFrameLeaked": shared_leaked,
        "outsideSeparationBands": int(np.count_nonzero(bands < 0)),
    }


def cell_verdict(cell, margin=None):
    """One cell's verdict. Four outcomes and no fifth; a ratio above 1 is its
    own finding rather than folded into "does not cancel", because
    anti-correlation is WORSE than the naive rule and hiding it would hide the
    one result arguing a span is harder than anyone assumed."""
    margin = _registered(
        CANCELLATION_MARGIN if margin is None else margin, "CANCELLATION_MARGIN"
    )
    if cell["ratio"] is None:
        return INSUFFICIENT_PAIRS
    if cell["ratio"] > 1.0:
        return ANTI_CORRELATED
    if cell["ratio"] < 1.0 - margin:
        return CANCELS_WITH_MARGIN
    if cell["ratio"] < 1.0:
        return CANCELS_WITHOUT_MARGIN
    return DOES_NOT_CANCEL


def seed_stability(observations, class_index, seeds=SEED_STABILITY_SEEDS):
    """The ratio at each registered seed. Randomness entered a measured path
    for the first time in this repository here, so a statistic that moves with
    the seed is a finding and is printed beside the result rather than
    discovered later."""
    return {
        str(seed): [cell["ratio"] for cell in cell_ratios(observations, class_index, seed=seed)["cells"]]
        for seed in seeds
    }


# --- The lateral estimand, and the filter that censors it -----------------

def lateral_summary(observations, class_index, radius):
    """The forward-backward round-trip displacement of one class's surviving
    samples, in depth pixels, reported ONLY beside the radius that produced it.

    The radius is a FILTER, not a measurement window: every observation that
    exists survived `dx^2 + dy^2 <= radius^2`, so this distribution is
    truncated from above and every statistic of it -- the median included -- is
    biased low. Reporting the median alone would be a measurement of the
    filter rather than of the sensor.

    `atBound` is the share of survivors within the last tenth of the radius.
    It is the diagnostic that says whether the truncation is doing the work: a
    distribution piled against its bound is one the filter shaped.
    """
    selected = (observations["k"] == SEPARATION_K) & (observations["class"] == class_index)
    displacement = np.hypot(
        observations["rt_dx"][selected], observations["rt_dy"][selected]
    )
    if displacement.size == 0:
        return {
            "class": CLASS_NAMES[class_index],
            "samples": 0,
            "medianPixels": None,
            "truncationRadiusPixels": float(radius),
            "atBound": None,
            "clearance": None,
        }
    median = fit.upper_median(displacement)
    return {
        "class": CLASS_NAMES[class_index],
        "samples": int(displacement.size),
        "medianPixels": median,
        "truncationRadiusPixels": float(radius),
        "atBound": float(np.count_nonzero(displacement >= 0.9 * radius) / displacement.size),
        # How far below its own bound the statistic sits, relatively. This is
        # the quantity the registered clearance is compared against.
        "clearance": (radius - median) / radius,
    }


def lateral_verdict(summary, clearance_margin=None):
    """Reportable only where the bound is not binding at the statistic.

    Registered before any data: the median must sit below the truncation
    radius by more than the registered relative clearance. Otherwise the number
    describes the filter and the lateral component stays REFUSED -- and the
    ROADMAP keeps its narrower entry, that the lateral has never been measured.
    """
    margin = _registered_clearance(
        LATERAL_CLEARANCE_MARGIN if clearance_margin is None else clearance_margin
    )
    if summary["medianPixels"] is None:
        return INSUFFICIENT_PAIRS
    return (
        LATERAL_REPORTABLE if summary["clearance"] > margin else LATERAL_REFUSED
    )


# --- The artifact ---------------------------------------------------------

def build_artifact(results, laterals, provenance, radius):
    """`skewline-span/1`: aggregates, verdicts and counts.

    **No per-row value appears here.** Not a frame index, not a pixel, not a
    depth, not a Delta-t, not a residual -- and not a minimum, a maximum or an
    illustrative example either, because an extremum IS a row. The `/2` files
    this is derived from are per-pixel and stay on the machine that made them;
    what enters the repository is this and nothing else.

    `spanInterval` is load-bearing rather than decorative: it stops a reader
    who sees a ratio below 1 from reading it as permission to print `1.42 m
    +/- 0.03`. The estimand is an upper median of absolute DISAGREEMENT, not a
    sigma, so there is nothing for a `+/-` to mean against it.
    """
    classes = {}
    for class_index, result in sorted(results.items()):
        name = CLASS_NAMES[class_index]
        lateral = laterals.get(class_index)
        classes[name] = {
            "axial": {
                "cells": result["cells"],
                "targetPixelCollisions": result["targetPixelCollisions"],
                "unmatchedPartners": result["unmatchedPartners"],
                "sharedFrameRejected": result["sharedFrameRejected"],
                "sharedFrameLeaked": result["sharedFrameLeaked"],
                "outsideSeparationBands": result["outsideSeparationBands"],
            },
            "lateral": lateral,
        }
    return {
        "schema": ARTIFACT_SCHEMA,
        "estimand": ESTIMAND,
        "units": UNITS,
        "component": COMPONENT,
        "outsideDomain": OUTSIDE_DOMAIN,
        "lateralEstimand": LATERAL_ESTIMAND,
        "lateralUnits": LATERAL_UNITS,
        "lateralClearanceFloor": LATERAL_CLEARANCE_FLOOR,
        "propagationRule": (
            "Var(r_b - r_a) = Var(r_a) + Var(r_b) - 2*Cov(r_a, r_b); the naive "
            "rule is Cov = 0, which gives sigma*sqrt(2). This artifact measures "
            "the third term and does not assume it. Axial only: it is a rule "
            "for one diagonal element of a point's error covariance and NOT "
            "for a distance."
        ),
        "spanInterval": "refused",
        "spanIntervalReason": (
            "the estimand is an upper median of absolute disagreement, not a "
            "sigma, so no coverage is defined against it; the component is "
            "axial, so it is not a distance; and no API here takes two points"
        ),
        "separationEdges": list(SEPARATION_EDGES),
        "depthMatchTolerance": DEPTH_MATCH_TOLERANCE,
        "pairsPerCell": PAIRS_PER_CELL,
        "minimumCellPairs": MINIMUM_CELL_PAIRS,
        "seed": SEED,
        "truncationRadiusPixels": float(radius),
        "measuredOn": [entry["session"] for entry in provenance],
        "export": provenance,
        "classes": classes,
    }


def write_artifact(path, artifact):
    with open(path, "w", encoding="utf-8") as handle:
        json.dump(artifact, handle, indent=2, sort_keys=True)
        handle.write("\n")


def read_artifact(path):
    with open(path, encoding="utf-8") as handle:
        artifact = json.load(handle)
    if artifact.get("schema") != ARTIFACT_SCHEMA:
        raise ValueError(f"{path}: not a {ARTIFACT_SCHEMA} artifact")
    return artifact
