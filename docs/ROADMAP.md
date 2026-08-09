# Roadmap

**Where this is:** v0.1 — everything but CI. The ladder is in the
[README](../README.md).

Each rung is entered only when the previous one runs. The test every rung has to
pass: **does the rung below force this, or would it merely look good here?** If
it is the second, it does not go in.

## What has shipped

Thirteen commits, in five steps. The decisions behind each are in
[`DEVLOG.md`](DEVLOG.md), including the ones that were mistakes.

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

**Next: CI, and it needs two jobs.** `swift test` on macOS never compiles the
sensor path, because that file sits entirely behind
`#if canImport(ARKit) && os(iOS)` and code inside a false branch is not
type-checked on that host. A green test suite therefore says nothing at all
about whether the device build works, so the device build is a separate job.

## What is next, and what forces it

| Version | Ships | What forces it |
|---|---|---|
| **v0.2** capture | ARKit session, AVFoundation frames, Core Motion rates, ImageIO depth and EXIF | Pose uncertainty has no signal without inertial rates and tracking state. Without this rung there is nothing to be uncertain about |
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
