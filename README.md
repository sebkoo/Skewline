# Skewline

[![CI](https://github.com/sebkoo/Skewline/actions/workflows/ci.yml/badge.svg?branch=main)](https://github.com/sebkoo/Skewline/actions/workflows/ci.yml)

Spatial capture for iOS, where every measurement carries its own confidence.

## The idea

Point a phone at a room and it will tell you where it is, to the centimetre. It
will not tell you how much to trust that centimetre — and those are very
different numbers. A tape measure that is sometimes off by 2 cm and sometimes
off by 30 cm reads exactly the same either way.

The name comes from the geometry. Observe the same point from two positions and
each observation is a ray; in theory the two rays meet at the point. They never
do. Sensor noise, tracking error and timing jitter leave a small gap, and two
lines in space that neither meet nor run parallel are called **skew lines**. The
width of that gap is the measurement's own account of how wrong it might be.
Most pipelines take the midpoint and throw the width away. This one keeps it.

## What is here today

Six modules, one harness app and the tests that hold them.

- **`Core`** — the measurement records: a pose with the uncertainty beside it
  and the tracker's own trust in that instant, an inertial sample, a camera
  frame, the depth captured with it, the exposure it was captured under and
  the intrinsics it was captured with. No I/O.
- **`Replay`** — the on-disk session format. A recorded session replays
  deterministically, which is what makes the pipeline testable on a laptop with
  no device attached.
- **`Capture`** — the ingest boundary. One consumer written against the protocol
  works unchanged against a recorded session or a live sensor, and there is a
  test that holds it there.
- **`Render`** — a depth pixel becomes a world point through the per-frame
  intrinsics and pose the container already carries — each point born with
  its sensor's confidence, and shaded by it. The accumulated cloud lives in
  one GPU buffer, re-shaded by a compute kernel and drawn to an offscreen
  image, both through one palette that keeps low, medium and high visibly
  distinct. Depends on `Core` and `Replay`, never `Capture`.
- **`Interop`** — a PLY point-cloud file read into Swift values across a
  deliberately C seam. The parsing — three encodings, arbitrary per-element
  property lists — lives in a C++ target behind a pure C header, so no C++
  type crosses a public signature and no importer inherits a language mode.
- **`Model`** — the fitted uncertainty model, read from the endpoint that
  serves it and evaluated locally. A class whose fit was refused still answers,
  from the banded table it kept; outside the depths it was fitted over, nothing
  answers, and those two silences are different cases a caller has to tell
  apart. What it hands back is the disagreement between two readings, not one
  reading's error bar, and it is named that way.

![44,973,892 points from one 31-second capture, each shaded by the depth
sensor's own confidence — blue where it trusts itself, amber where less, red
where it does not.](docs/media/cloud-confidence.png)

*One capture's accumulated cloud, confidence as color. 21.4% of this scene is
less than fully trusted — a map alone would have looked uniformly
authoritative. Reproduce it from any capture:
`swift run -c release RenderProbe <container> --png <dir>`.*

The app is `App/SkewlineHarness`: a start button, a stop button and a panel of
what the run measured. It exists to put the pipeline in front of real sensors
and produce containers a Mac can replay, and it should not grow a second job.

```sh
swift build && swift test
```

Four CI jobs run on every push to `main`. One runs that test suite on macOS.
One builds for iOS — because the sensor path is behind
`#if canImport(ARKit) && os(iOS)`, and code inside a false branch is never
type-checked, so the macOS tests can be green while that file is not even valid
Swift. The third fails when this README contradicts the repository — detection
only, and the fix stays a human commit. The fourth runs the fit harness in
`Fit/` — Python and numpy, because an uncertainty model has to be fitted
somewhere — whose tests plant known model parameters in synthetic data and
require the fit to recover them, or to refuse. That same job covers the
endpoint that serves the fitted model, which lives beside the fit and shares
its reader; a service that re-parsed the artifact would be a second reader to
drift.

## Where this goes

Each rung is entered only when the one below it runs.

```text
v0.1  foundation   types · replay · ingest boundary · tests · CI       done
v0.2  capture      ARKit · camera frames · device motion · depth       done
v0.3  render       a point cloud shaded by its own confidence         done
v0.4  measure      frame time, and drift under replay                 done
v0.5  interop      a point-cloud reader over Swift–C++                done
v0.6  fit          the uncertainty model, fitted offline              done
v0.7  service      the fitted model reaches the device                here
v0.8  view         a dashboard over the same service
```

Rungs are planned; individual commits are not. What each commit contains is
decided by what the one before it turned out to be wrong about — which is why
[`docs/DEVLOG.md`](docs/DEVLOG.md) records the mistakes alongside the decisions.
[`docs/ROADMAP.md`](docs/ROADMAP.md) says what forces each rung, and what is
deliberately never built.

## What is not here

There is no interactive viewer — `Render` draws the cloud to an offscreen
image, never to a window — and no reconstruction. Rates, budgets and payload
sizes are measured and recorded in [`docs/DEVLOG.md`](docs/DEVLOG.md), and so,
now, is a first measured error scale: the confidence classes are calibrated
against observed cross-frame disagreement, high 3.1–10.8 mm and low
18.9–197.2 mm depending on depth band, ordering held in 16 of 16 comparisons
with margin. **What is still not here is pose error against ground truth** —
there is no truth rig, and cross-frame reprojection measures the joint
pose-and-depth disagreement a replay can observe, not pose accuracy on its
own. A number that has not been measured is worse than no number.

Nothing is deployed. The fitted model is served by a local endpoint bound to
loopback, not by a host somebody operates, and no secret or hostname is in
this repository. The wire runs one way: what it carries down is the same
aggregate artifact already committed here, and nothing from a capture goes
up — no frames, no depth, no observation rows, and no per-point query, since
asking "how wrong is a reading at this depth" would send the asker's own
depths to whoever runs the service. The client evaluates the model itself,
and that client now exists.

Reconstruction is deliberately out of scope. This is the layer underneath it:
any reconstruction is only as trustworthy as its input, and today that input
arrives with no confidence attached.

## Licence

See [`LICENSE`](LICENSE).
