# Roadmap

Three time-scales live in three places. This page is the middle one: what has
been built, what the next few commits are, and what each future rung is waiting
on. The [README](../README.md) has the ladder at a glance;
[`DEVLOG.md`](DEVLOG.md) has what actually happened, including the mistakes.

Each rung is entered only when the previous one runs. The test every rung has to
pass: **does the rung below force this, or would it merely look good here?** If
it is the second, it does not go in.

## The shape of it

Three modules. The graph is acyclic with `Core` at the root, and it is enforced
by the compiler rather than by anyone's discipline.

```text
Core        done      a pose and its uncertainty, carried as one value.
 │                    No I/O, no dependencies.
 │
 ├─ Replay  done      the session format on disk. Depends on Core and
 │                    nothing else — which is what keeps the whole test
 │                    suite runnable with no device attached.
 │
 └─ Capture done      the ingest boundary. Depends on Core and Replay.
     │
     ├─ SensorSource          the live path, iOS only, behind
     │                        #if canImport(ARKit) && os(iOS)
     └─ ReplaySessionSource   the recorded path
```

`Replay` must never depend on `Capture`. Replay is what makes the pipeline
testable without hardware, so anything it imports becomes a thing every test
drags along.

Where the rest attaches:

```text
v0.2  sensors    ARKit, camera frames, device motion, depth, into Capture
v0.3  Render     reads Core values, shades each point by its confidence
v0.4  Measure    replays sessions, compares predicted error to observed
v0.5  Interop    fills Core from a point-cloud file, over Swift ↔ C++
v0.6  Fit        consumes replayed sessions offline and fits the model
v0.7  Service    serves what Fit produced, back to the device
v0.8  View       reads Service
```

Nothing above v0.2 touches `Core`'s shape. If a later rung needs `Core` to
change, that is a signal the boundary was drawn wrong, and it belongs in
[`DEVLOG.md`](DEVLOG.md) before it belongs in a diff.

## What has shipped

Six steps. The decisions behind each are in [`DEVLOG.md`](DEVLOG.md), including
the ones that were mistakes.

1. **Types.** A pose, a 6×6 covariance beside it, and the tracker's own opinion
   of itself at that instant — carried as one value, `Codable` and `Sendable`,
   so the estimate and its uncertainty cannot drift apart.
2. **Replay.** The on-disk session format, and a test that round-trips a whole
   session through a file. Verified to go red when the codec is deliberately
   broken, because a test that has never failed has never been tested.
3. **The ingest boundary.** A protocol with two conformers — a recorded session
   and a live sensor — and a test that one consumer works unchanged against
   either. A protocol with a single implementation is a type with extra steps.
4. **The name.** One line of `Package.swift`.
5. **Public.** Licence, project brief, roadmap, readme.
6. **CI, in two jobs.** `swift test` on macOS never compiles the sensor path,
   because that file sits behind `#if canImport(ARKit) && os(iOS)` and code
   inside a false branch is not type-checked on that host. A green suite
   therefore says nothing about the device build, so the device build is a
   second job that builds the `Skewline-Package` umbrella scheme for
   `generic/platform=iOS`.

## Decided but not yet done

A list that only shrinks. Anything finished moves to *What has shipped* above
rather than gaining a tick here, so this section is empty when there is nothing
outstanding — which is the honest resting state, not a gap.

```text
  .claude/settings.json — the staging and force-push rules that the briefs
  currently state as advice, turned into refusals
───────────────────────────────────────────────────────────────────────────
  v0.2 capture is a rung, not a commit list. Nothing below this line is
  decided at commit level, and nothing should be.
```

Below that line, what each commit contains is decided by what the one before it
turned out to be wrong about. That is why [`DEVLOG.md`](DEVLOG.md) records the
mistakes and not only the decisions: it is the input to the next commit rather
than a diary. Commit 2's shape came out of commit 1's report; commit 5 exists
because commit 2 discovered that `canImport(ARKit)` is true on macOS.

## What is next, and what forces it

| Version | Ships | What forces it |
|---|---|---|
| **v0.2** capture | ARKit session, its camera frames, Core Motion rates, ImageIO depth and EXIF | Pose uncertainty has no signal without inertial rates and tracking state. Without this rung there is nothing to be uncertain about |
| **v0.3** render | Accumulated point cloud, each point shaded by its confidence, Metal compute kernel | Tens of millions of points in a thirty-second capture cannot be re-shaded on the CPU per frame. The arithmetic forces the kernel, not the taste |
| **v0.4** measure | Frame time, upload bandwidth, drift under replay | "A result needs a confidence" is an empty claim until the confidence is calibrated against something observed |
| **v0.5** interop | Point-cloud / PLY reader over Swift–C++ | A format with dozens of properties per point is the wrong job for Swift, and the interop seam is itself a design question worth answering in public |
| **v0.6** fit | Offline fit of the uncertainty model from replayed sessions | The model is *fitted*, not measured. Fitting is numpy's job, and it is what closes the thesis |
| **v0.7** service | The fit becomes an endpoint; the client uploads a bundle and gets a model back | Once the fit exists offline, shipping it to the device is the only way it reaches a user |
| **v0.8** view | A small web dashboard over the same service | Nearly free once v0.7 exists. Drops entirely if v0.7 slips |

Note the chain from v0.5 down. Python does not enter because Python is popular —
it enters because an uncertainty model has to be fitted somewhere; once it is
fitted offline the network seam is the only way it reaches the phone; and once
there is a service a dashboard costs a day. Each rung is pulled in by the one
below it. That is the difference between a ladder and a checklist.

## Deliberately not built

On-device inference, document scanning, and location services. None of them has
a job in an indoor spatial-capture pipeline today. The honest answer to "why is
this here?" would be embarrassing, and a reader can tell.

On-device inference has a written trigger rather than a plan: if the analytic
error model is **measured** to break down under some material or lighting
condition, that measurement justifies a learned component. Before the
measurement it is decoration.

## Sequencing

v0.1 is days. v0.2 through v0.4 is where this becomes real or stalls, and
nothing below v0.4 is worth starting until a device is producing sessions that
replay deterministically. If time runs short, stopping cleanly at v0.4 with four
things done properly beats eight things half-wired.
