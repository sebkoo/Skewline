# Skewline

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

## What is not here

No app, no interface, no rendering, no reconstruction — and **no accuracy
figures**, because nothing has been measured yet. A number that has not been
measured is worse than no number.

Reconstruction is deliberately out of scope. This is the layer underneath it:
any reconstruction is only as trustworthy as its input, and today that input
arrives with no confidence attached.

[`docs/ROADMAP.md`](docs/ROADMAP.md) says what enters next and what forces it.
[`docs/DEVLOG.md`](docs/DEVLOG.md) is the running record of decisions and
surprises, including the ones that were mistakes.

## Licence

See [`LICENSE`](LICENSE).
