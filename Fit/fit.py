"""The offline fit of the uncertainty model, and the registered criteria it
runs under.

This module consumes the observation files CalibrationProbe exports
(`--dump-observations`) and fits a continuous per-class error model --
median |delta| as a function of source depth -- against the incumbent
banded table. Everything registered lives here as a module constant or a
fixed procedure: the candidate forms, the fitting objective, the
leave-one-out split, the metric, the adoption bar and the refusal outcome.
numpy is the only dependency; the tests are stdlib unittest.

The estimand, fixed in advance: the upper median |delta| of same-class
cross-frame reprojection at k=1 under the registered filter chain, in
meters, PAIRWISE -- the disagreement of two same-class readings, not a
single-reading sigma. A consumer that wants a per-reading error bar must
say how it converts, and that conversion is not this module's claim.

The fit must be allowed to lose. Per class, a continuous form is adopted
only if it beats the fold's own banded table strictly in every fold;
anything less and that class's model REMAINS the table. Refusal is a
finding, not a failure.
"""

import json

import numpy as np

# --- Registered constants -------------------------------------------------

SCHEMA_TAG = "skewline-observations/1"
GEOMETRY_SCHEMA_TAG = "skewline-observations/2"
ARTIFACT_SCHEMA = "skewline-fit/1"

# The two export shapes, by name and in file order. /2 appends to /1 and never
# reorders it: the first five columns mean the same thing in both, so the fit
# below reads a /2 file without knowing what the extra ones are for, and the
# artifact fitted from /1 files stays reproducible from them.
COLUMNS_V1 = ("k", "delta_t", "class", "depth", "delta")
COLUMNS_V2 = COLUMNS_V1 + (
    "src_frame", "tgt_frame", "src_x", "src_y", "tgt_x", "tgt_y", "rt_dx", "rt_dy",
)
SCHEMA_COLUMNS = {SCHEMA_TAG: COLUMNS_V1, GEOMETRY_SCHEMA_TAG: COLUMNS_V2}
INTEGER_COLUMNS = frozenset(
    {"k", "class", "src_frame", "tgt_frame", "src_x", "src_y", "tgt_x", "tgt_y"}
)

ESTIMAND = (
    "upper median |delta| of same-class cross-frame reprojection at k=1 "
    "under the registered filter chain, meters, pairwise -- not a "
    "single-reading sigma"
)
UNITS = "meters"
OUTSIDE_DOMAIN = "refuse"

# The pair the artifact carries: two bare numbers, because `skewline-fit/1`
# settles no inclusivity marker for them. Two different questions are asked of
# these same two endpoints below, and they answer differently at the top one.
DEPTH_DOMAIN = (0.5, 5.0)
BAND_EDGES = (0.5, 1.0, 2.0, 3.0, 5.0)
CLASS_NAMES = ("low", "medium", "high")

CANDIDATE_FORMS = ("affine", "quadratic", "power")

# The power exponent's registered grid: [0.5, 3.0] in steps of 0.05.
POWER_GRID = np.linspace(0.5, 3.0, 51)

# IRLS for the L1 (pinball tau = 0.5) objective: fixed iteration count and
# residual floor, initialized from the unweighted least squares -- no knob
# is chosen at fit time.
IRLS_ITERATIONS = 50
IRLS_EPSILON = 1e-9

# The positivity gate's grid: 0.01 m steps across the depth domain, CLOSED at
# both ends. The question is "may this candidate be adopted", and a form that
# goes non-positive at 5.0 m is disqualified whether or not any consumer ever
# asks there -- so 5.0 is on this grid.
POSITIVITY_GRID = np.linspace(DEPTH_DOMAIN[0], DEPTH_DOMAIN[1], 451)

# The other question over the same two endpoints: "does a consumer get a number
# at depth d", asked by `estimate` below and HALF-OPEN, [0.5, 5.0) -- the
# reading `Sources/Model` resolved from the banded table's own arithmetic,
# where the last band is [3.0, 5.0) and 5.0 falls in no band at all. An alias
# and not a second pair: the numbers are one object, the half-openness lives in
# `estimate`'s comparison rather than in the constant, and what enforces the
# difference from the gate above is a test that pins 5.0 answering differently
# in the two.
ANSWERING_DOMAIN = DEPTH_DOMAIN

# The depth ladder every reader of this model reports at, straddling both edges
# of the answering domain so that one report shows what answers and what
# refuses. Registered in docs/DEVLOG.md, v0.8 commit 2. `view.py` imports it;
# `Sources/ModelProbe/ModelProbe.swift` carries the same eight numbers because
# Swift cannot read a Python constant, and `test_fit.py` reads that declaration
# and pins the two equal.
DEPTH_LADDER = (0.4, 0.5, 1.0, 2.0, 3.0, 4.9, 5.0, 6.0)

# Diagnostics only -- never the fit path: fine bins printed beside the fit.
DIAGNOSTIC_BIN_WIDTH = 0.1
DIAGNOSTIC_MIN_SAMPLES = 100


# --- Registered statistics ------------------------------------------------

def upper_median(values):
    """The repository's registered median: sorted[n // 2], no averaging of
    the middle pair -- the exact statistic the Swift analysis reports."""
    values = np.asarray(values, dtype=float)
    if values.size == 0:
        raise ValueError("upper_median of an empty sample")
    return float(np.partition(values, values.size // 2)[values.size // 2])


def weighted_median(values, weights):
    """The smallest value whose cumulative weight strictly exceeds half the
    total -- reduces to `upper_median` under equal weights."""
    values = np.asarray(values, dtype=float)
    weights = np.asarray(weights, dtype=float)
    order = np.argsort(values, kind="stable")
    ordered = values[order]
    cumulative = np.cumsum(weights[order])
    index = np.searchsorted(cumulative, cumulative[-1] / 2, side="right")
    return float(ordered[min(index, ordered.size - 1)])


# --- The candidate forms --------------------------------------------------

def fit_table(depth, abs_delta, edges=BAND_EDGES):
    """The incumbent: one upper median per registered band."""
    medians = []
    for low, high in zip(edges[:-1], edges[1:]):
        inside = (depth >= low) & (depth < high)
        medians.append(upper_median(abs_delta[inside]) if inside.any() else None)
    return {"edges": list(edges), "medians": medians}


def _irls_l1(design, target):
    coefficients, *_ = np.linalg.lstsq(design, target, rcond=None)
    for _ in range(IRLS_ITERATIONS):
        residuals = np.abs(target - design @ coefficients)
        scale = np.sqrt(1.0 / np.maximum(residuals, IRLS_EPSILON))
        coefficients, *_ = np.linalg.lstsq(
            design * scale[:, None], target * scale, rcond=None
        )
    return coefficients


def fit_form(name, depth, abs_delta):
    """Fits one candidate by the registered objective -- pinball loss at
    tau = 0.5 on the raw observations, the same objective the selection
    metric scores."""
    depth = np.asarray(depth, dtype=float)
    abs_delta = np.asarray(abs_delta, dtype=float)
    if name == "affine":
        a, b = _irls_l1(np.column_stack([np.ones_like(depth), depth]), abs_delta)
        return {"a": float(a), "b": float(b)}
    if name == "quadratic":
        a, b = _irls_l1(np.column_stack([np.ones_like(depth), depth * depth]), abs_delta)
        return {"a": float(a), "b": float(b)}
    if name == "power":
        # Closed form per grid exponent: for fixed p the L1-optimal scale is
        # the weighted median of |delta| / d^p with weights d^p. Ties on the
        # loss keep the lower exponent -- strict improvement only.
        best = None
        for p in POWER_GRID:
            lever = depth ** p
            a = weighted_median(abs_delta / lever, lever)
            loss = float(np.mean(np.abs(abs_delta - a * lever)))
            if best is None or loss < best[0]:
                best = (loss, a, float(p))
        return {"a": best[1], "p": best[2]}
    raise ValueError(f"unknown form {name!r}")


def predict(name, coefficients, depth):
    """sigma-hat(d) for one candidate. The table refuses (NaN) outside its
    bands; the parametric forms are evaluated wherever asked, and the
    positivity gate polices the domain."""
    depth = np.asarray(depth, dtype=float)
    if name == "table":
        edges = coefficients["edges"]
        medians = coefficients["medians"]
        out = np.full(depth.shape, np.nan)
        for i, (low, high) in enumerate(zip(edges[:-1], edges[1:])):
            if medians[i] is not None:
                out[(depth >= low) & (depth < high)] = medians[i]
        return out
    if name == "affine":
        return coefficients["a"] + coefficients["b"] * depth
    if name == "quadratic":
        return coefficients["a"] + coefficients["b"] * depth * depth
    if name == "power":
        return coefficients["a"] * depth ** coefficients["p"]
    raise ValueError(f"unknown form {name!r}")


def positive_on_domain(name, coefficients):
    """The positivity gate: sigma-hat must exceed zero on the whole
    registered grid, or the candidate is disqualified before selection."""
    return bool(np.all(predict(name, coefficients, POSITIVITY_GRID) > 0))


# --- The registered selection ----------------------------------------------

def holdout_l1(name, coefficients, depth, abs_delta):
    """The registered metric: mean per-observation L1 against sigma-hat."""
    prediction = predict(name, coefficients, depth)
    if np.isnan(prediction).any():
        raise ValueError("prediction refused inside the holdout's own domain")
    return float(np.mean(np.abs(abs_delta - prediction)))


def select_for_class(containers):
    """Leave-one-out over the containers for one class.

    `containers` is a list of (name, depth, abs_delta) triples, k=1 rows
    only. Each fold holds one container out and builds BOTH candidates --
    every parametric form and the banded table it must beat -- from the
    remaining containers, so the comparison is symmetric. A form is adopted
    only if it beats the fold's table strictly in all folds; ties go to the
    incumbent. Among all-fold winners the lowest unweighted mean of the
    per-fold metrics wins (one container, one vote), and the winner refits
    on every container for the final coefficients -- which are therefore
    never themselves holdout-validated; only the form is.
    """
    if len(containers) < 2:
        raise ValueError("leave-one-out needs at least two containers")
    folds = []
    for i, (holdout_name, holdout_depth, holdout_abs) in enumerate(containers):
        train_depth = np.concatenate(
            [c[1] for j, c in enumerate(containers) if j != i]
        )
        train_abs = np.concatenate(
            [c[2] for j, c in enumerate(containers) if j != i]
        )
        table = fit_table(train_depth, train_abs)
        table_metric = holdout_l1("table", table, holdout_depth, holdout_abs)
        fold = {"holdout": holdout_name, "table": table_metric, "forms": {}}
        for name in CANDIDATE_FORMS:
            coefficients = fit_form(name, train_depth, train_abs)
            if not positive_on_domain(name, coefficients):
                fold["forms"][name] = {"disqualified": True}
                continue
            metric = holdout_l1(name, coefficients, holdout_depth, holdout_abs)
            fold["forms"][name] = {
                "metric": metric,
                "margin": table_metric - metric,
            }
        folds.append(fold)

    def beats_everywhere(name):
        return all(
            "metric" in fold["forms"][name]
            and fold["forms"][name]["metric"] < fold["table"]
            for fold in folds
        )

    winners = [name for name in CANDIDATE_FORMS if beats_everywhere(name)]
    all_depth = np.concatenate([c[1] for c in containers])
    all_abs = np.concatenate([c[2] for c in containers])
    result = {"folds": folds, "table": fit_table(all_depth, all_abs)}
    if winners:
        winner = min(
            winners,
            key=lambda name: np.mean([f["forms"][name]["metric"] for f in folds]),
        )
        result["verdict"] = "adopted"
        result["form"] = winner
        result["coefficients"] = fit_form(winner, all_depth, all_abs)
    else:
        result["verdict"] = "refused"
    return result


# --- Diagnostics (printed beside the fit, never the fit path) --------------

def diagnostic_bins(depth, abs_delta):
    """Fine-binned medians for the report: 0.1 m bins over the domain, bins
    short of the registered minimum counted rather than summarized."""
    rows = []
    edges = np.arange(DEPTH_DOMAIN[0], DEPTH_DOMAIN[1] + 1e-9, DIAGNOSTIC_BIN_WIDTH)
    for low, high in zip(edges[:-1], edges[1:]):
        inside = (depth >= low) & (depth < high)
        count = int(inside.sum())
        rows.append({
            "low": float(low),
            "count": count,
            "median": upper_median(abs_delta[inside])
            if count >= DIAGNOSTIC_MIN_SAMPLES else None,
        })
    return rows


# --- The observation files --------------------------------------------------

def read_observations(path):
    """One CalibrationProbe export, of either schema: the `#` provenance
    header, then bare rows. The tag is checked before anything is believed,
    and the tag alone decides how many columns there must be.

    Both `/1` and `/2` are read here rather than in two readers. The columns
    the fit uses are the first five of either, so a second reader would be a
    second copy of the same positional agreement -- the drift `serve.py` and
    `view.py` already refused to create.
    """
    header = []
    with open(path, encoding="utf-8") as handle:
        for line in handle:
            if not line.startswith("#"):
                break
            header.append(line[1:].strip())
    tag = header[0] if header else ""
    columns = SCHEMA_COLUMNS.get(tag)
    if columns is None:
        known = " or ".join(sorted(SCHEMA_COLUMNS))
        raise ValueError(f"{path}: not a {known} file")
    metadata = {}
    survivors = {}
    intrinsics = {}
    for line in header[1:]:
        key, _, value = line.partition(" ")
        if key == "survivors":
            bucket, _, count = value.rpartition(" ")
            survivors[bucket] = int(count)
        elif key == "intrinsics":
            frame, fx, fy, cx, cy = value.split()
            intrinsics[int(frame)] = (float(fx), float(fy), float(cx), float(cy))
        else:
            metadata[key] = value
    # The `# columns` line has been written since v0.6 and never read. A
    # writer that silently reordered its columns would otherwise be a green
    # suite and wrong numbers everywhere, because every consumer below is
    # positional.
    declared = metadata.get("columns")
    if declared is not None and tuple(declared.split(",")) != columns:
        raise ValueError(
            f"{path}: header declares columns {declared}, expected {','.join(columns)}"
        )
    data = np.loadtxt(path, delimiter=",", comments="#", ndmin=2)
    if data.size == 0:
        data = np.empty((0, len(columns)))
    if data.shape[1] != len(columns):
        raise ValueError(
            f"{path}: {tag} expects {len(columns)} columns, found {data.shape[1]}"
        )
    observations = {
        "session": metadata.get("session", ""),
        "schema": tag,
        "metadata": metadata,
        "survivors": survivors,
        "intrinsics": intrinsics,
    }
    for index, name in enumerate(columns):
        column = data[:, index]
        observations[name] = column.astype(int) if name in INTEGER_COLUMNS else column
    return observations


def load_class_containers(paths):
    """Splits each export into per-class (session, depth, |delta|) triples,
    k=1 rows only -- the registered data. Returns ({class index: [triples]},
    provenance)."""
    containers = {0: [], 1: [], 2: []}
    provenance = []
    for path in paths:
        observations = read_observations(path)
        first = observations["k"] == 1
        for class_index in (0, 1, 2):
            inside = first & (observations["class"] == class_index)
            containers[class_index].append((
                observations["session"],
                observations["depth"][inside],
                np.abs(observations["delta"][inside]),
            ))
        provenance.append({
            "session": observations["session"],
            "decimation": int(observations["metadata"].get("decimation", 0)),
        })
    return containers, provenance


# --- The fitted artifact -----------------------------------------------------

def build_artifact(class_results, provenance):
    """The registered `skewline-fit/1` shape: estimand, units and
    out-of-domain behavior fixed here so no consumer invents them; per
    class either the adopted form or the refused class's table, with every
    fold's metrics and margins beside it."""
    classes = {}
    for class_index, result in class_results.items():
        entry = {"verdict": result["verdict"], "folds": result["folds"]}
        if result["verdict"] == "adopted":
            entry["form"] = result["form"]
            entry["coefficients"] = result["coefficients"]
        else:
            entry["table"] = result["table"]
        classes[CLASS_NAMES[class_index]] = entry
    return {
        "schema": ARTIFACT_SCHEMA,
        "estimand": ESTIMAND,
        "units": UNITS,
        "outsideDomain": OUTSIDE_DOMAIN,
        "depthDomain": list(DEPTH_DOMAIN),
        "trainedOn": [p["session"] for p in provenance],
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


# --- What the model answers, and where it refuses -----------------------------

# The four cases `Sources/Model`'s `Estimate` names, mirrored here so the two
# consumers of one artifact refuse in the same places. Two are answers and two
# are silences, and the silences are different findings: inside the domain a
# band nobody sampled has no median, while outside it nothing answers at all.
FROM_ADOPTED_FORM = "from-adopted-form"
FROM_BANDED_TABLE = "from-banded-table"
REFUSED_BAND_WITHOUT_SAMPLES = "refused-band-without-samples"
REFUSED_OUTSIDE_DEPTH_DOMAIN = "refused-outside-depth-domain"


def estimate(class_model, depth):
    """What one class of the artifact answers at one depth, or which silence.

    `predict` is the shared evaluator and deliberately NOT a shared refuser:
    the parametric forms are evaluated wherever asked, so it returns a number
    at 6.0 m where a consumer must refuse, and its table path returns a bare
    NaN for two silences that are not one thing. This is the refuser, and it
    mirrors `Estimate` case for case rather than being a second arithmetic.

    Returns `{"case": <one of the four above>, "meters": float or None}`.

    Four cases and no fifth. A verdict this module cannot name, a form it has
    no arithmetic for, and a table that does not span the depth domain -- the
    last of which the Swift decoder refuses an artifact over -- all raise
    ValueError, exactly as `predict` raises on an unknown form. Inventing an
    unnamed silence here would be, in the other language, the failure that
    type exists to prevent.
    """
    low, high = ANSWERING_DOMAIN
    # Half-open, and asked first: outside the domain nothing answers, for an
    # adopted class exactly as for a refused one.
    if not low <= depth < high:
        return {"case": REFUSED_OUTSIDE_DEPTH_DOMAIN, "meters": None}
    verdict = class_model.get("verdict")
    if verdict == "adopted":
        coefficients = class_model.get("coefficients")
        if not isinstance(coefficients, dict):
            raise ValueError("an adopted class with no coefficients to evaluate")
        try:
            return {
                "case": FROM_ADOPTED_FORM,
                "meters": float(predict(class_model.get("form"), coefficients, depth)),
            }
        except KeyError as missing:
            raise ValueError(
                f"{class_model.get('form')!r} without its {missing} coefficient"
            ) from missing
    if verdict == "refused":
        # A refused class still answers -- from the banded table it kept,
        # which is exactly what keeping it bought.
        table = class_model.get("table")
        if not isinstance(table, dict):
            raise ValueError("a refused class with no table to answer from")
        edges = table.get("edges", [])
        medians = table.get("medians", [])
        for index, (band_low, band_high) in enumerate(zip(edges[:-1], edges[1:])):
            if band_low <= depth < band_high and index < len(medians):
                median = medians[index]
                if median is None:
                    return {"case": REFUSED_BAND_WITHOUT_SAMPLES, "meters": None}
                return {"case": FROM_BANDED_TABLE, "meters": float(median)}
        raise ValueError(
            f"no band holds {depth} in a table that must span {list(ANSWERING_DOMAIN)}"
        )
    raise ValueError(f"unknown verdict {verdict!r}")


# --- The driver the measured commit will run ---------------------------------

def main(argv):
    if len(argv) < 4:
        print("usage: fit.py <artifact.json> <observations.csv> "
              "<observations.csv> ...")
        return 64
    out_path, csv_paths = argv[1], argv[2:]
    containers, provenance = load_class_containers(csv_paths)
    class_results = {}
    for class_index in (0, 1, 2):
        name = CLASS_NAMES[class_index]
        result = select_for_class(containers[class_index])
        class_results[class_index] = result
        print(f"class {name}: {result['verdict']}"
              + (f" ({result['form']})" if result["verdict"] == "adopted" else ""))
        for fold in result["folds"]:
            forms = "  ".join(
                f"{form} disqualified" if "disqualified" in entry
                else f"{form} {entry['metric']:.6f} (margin {entry['margin']:+.6f})"
                for form, entry in fold["forms"].items()
            )
            print(f"  holdout {fold['holdout']}: table {fold['table']:.6f}  {forms}")
        depth = np.concatenate([c[1] for c in containers[class_index]])
        abs_delta = np.concatenate([np.abs(c[2]) for c in containers[class_index]])
        for row in diagnostic_bins(depth, abs_delta):
            median = "short" if row["median"] is None else f"{row['median']:.6f}"
            print(f"  bin {row['low']:.1f} n {row['count']} median {median}")
    write_artifact(out_path, build_artifact(class_results, provenance))
    print(f"wrote {out_path}")
    return 0


if __name__ == "__main__":
    import sys

    sys.exit(main(sys.argv))
