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

Three modules and a handful of tests.

- **`Core`** — one observation from a camera frame: the pose, the uncertainty
  beside it, and how much the tracker trusted itself at that instant. No I/O.
- **`Replay`** — the on-disk session format. A recorded session replays
  deterministically, which is what makes the pipeline testable on a laptop with
  no device attached.
- **`Capture`** — the ingest boundary. One consumer written against the protocol
  works unchanged against a recorded session or a live sensor, and there is a
  test that holds it there.

```sh
swift build && swift test
```

Two CI jobs run on every push to `main`. One runs that test suite on macOS. The
other builds for iOS — because the sensor path is behind
`#if canImport(ARKit) && os(iOS)`, and code inside a false branch is never
type-checked, so the macOS tests can be green while that file is not even valid
Swift.

## Where this goes

Each rung is entered only when the one below it runs.

```text
v0.1  foundation   types · replay · ingest boundary · tests · CI       done
v0.2  capture      ARKit · camera frames · device motion · depth       next
v0.3  render       a point cloud shaded by its own confidence
v0.4  measure      frame time, and drift under replay
v0.5  interop      a point-cloud reader over Swift–C++
v0.6  fit          the uncertainty model, fitted offline
v0.7  service      the fitted model reaches the device
v0.8  view         a dashboard over the same service
```

Rungs are planned; individual commits are not. What each commit contains is
decided by what the one before it turned out to be wrong about — which is why
[`docs/DEVLOG.md`](docs/DEVLOG.md) records the mistakes alongside the decisions.
[`docs/ROADMAP.md`](docs/ROADMAP.md) says what forces each rung, and what is
deliberately never built.

## What is not here

No app, no interface, no rendering, no reconstruction — and **no accuracy
figures**, because nothing has been measured yet. A number that has not been
measured is worse than no number.

Reconstruction is deliberately out of scope. This is the layer underneath it:
any reconstruction is only as trustworthy as its input, and today that input
arrives with no confidence attached.

## Licence

See [`LICENSE`](LICENSE).
