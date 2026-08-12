# Roadmap

Three time-scales live in three places. This page is the middle one: what has
been built, what the next few commits are, and what each future rung is waiting
on. The [README](../README.md) has the ladder at a glance;
[`DEVLOG.md`](DEVLOG.md) has what actually happened, including the mistakes.

Each rung is entered only when the previous one runs. The test every rung has to
pass: **does the rung below force this, or would it merely look good here?** If
it is the second, it does not go in.

## The shape of it

Five modules. The graph is acyclic with `Core` at the root, and it is enforced
by the compiler rather than by anyone's discipline.

```text
Core        done      a pose and its uncertainty, carried as one value.
 │                    No I/O, no dependencies.
 │
 ├─ Replay  done      the session format on disk. Depends on Core and
 │                    nothing else — which is what keeps the whole test
 │                    suite runnable with no device attached.
 │
 ├─ Capture done      the ingest boundary. Depends on Core and Replay.
 │   │
 │   ├─ SensorSource          the live path, iOS only, behind
 │   │                        #if canImport(ARKit) && os(iOS)
 │   └─ ReplaySessionSource   the recorded path
 │
 └─ Render  done      depth pixels into world points, each with its
                      confidence. Depends on Core and Replay, never
                      Capture.

Interop     done      a PLY point-cloud file read across a C seam into
                      the module's own value types. Depends on nothing
                      above -- the C++ parser is a private target behind
                      a pure C header, so no importer inherits a
                      language mode from it.
```

`Replay` must never depend on `Capture`. Replay is what makes the pipeline
testable without hardware, so anything it imports becomes a thing every test
drags along.

Where the rest attaches:

```text
v0.2  capture    ARKit, camera frames, device motion, depth, into Capture
v0.3  Render     reads Core values, shades each point by its confidence
v0.4  Measure    replays sessions, compares predicted error to observed
v0.5  Interop    reads a point-cloud file across a C seam, into its own types
v0.6  Fit        consumes replayed sessions offline and fits the model
v0.7  Service    serves what Fit produced, back to the device
v0.8  View       reads Service
```

Nothing above v0.2 touches `Core`'s shape. If a later rung needs `Core` to
change, that is a signal the boundary was drawn wrong, and it belongs in
[`DEVLOG.md`](DEVLOG.md) before it belongs in a diff.

## What has shipped

Twenty-three steps. The decisions behind each are in [`DEVLOG.md`](DEVLOG.md),
including the ones that were mistakes.

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
7. **The live sensor path.** `SensorSource` streams pose observations and
   camera frames from a live `ARSession`, established through
   `run(_:options:)` rather than the session directly — one call that stamps
   the shared timeline origin every sequence in a capture is measured
   against.
8. **The capture harness.** `App/SkewlineHarness`: a start button, a stop
   button and a panel of what the run measured. It exists to put the
   pipeline in front of real sensors and produce containers a Mac can
   replay.
9. **Device motion.** Core Motion's fused device motion, requested at
   200 Hz and delivered at a measured 99.45 Hz ceiling, on the same
   timeline as the pose sequence — two independent sequences aligned only
   by sharing one origin, never resampled onto each other.
10. **Camera frames.** JPEG-encoded frames written into the session
    container beside `session.json`, associated with their `FrameRecord` by
    position, with a `PixelBufferPacking` step pulled out of the ARKit gate
    specifically so the Mac test suite can prove it.
11. **Depth.** LiDAR `sceneDepth` — and its per-pixel confidence — packed
    tight and LZFSE-compressed beside each frame that has it, an optional
    per-frame record so a device without the sensor, or a warm-up frame
    before it, decodes unchanged.
12. **Camera exposure.** `ARCamera.exposureDuration` and `.exposureOffset` —
    the blur product's camera-side operand, and the cheapest
    scene-illumination scalar ARKit types — riding `FrameRecord` as an
    optional sub-record, the depth pattern exactly.
13. **Camera intrinsics.** `ARCamera.intrinsics` — the pinhole focal length
    and principal point unprojection needs — and the pixel resolution they
    are expressed at, riding `FrameRecord` as an optional sub-record, the
    exposure pattern exactly. v0.2 had shipped a container carrying pose and
    depth without the operand its own v0.3 successor needs; this closes that
    gap before the render rung opens.
14. **Unprojection.** A fourth module, `Render` — depth pixel → camera ray →
    world point on the CPU, every point born with its sensor's confidence —
    with the depth-payload decode landing in `Replay` as the format's
    inverse, and a probe that replayed four real containers through the
    arithmetic: 75,988,992 points at a measured 57.8 M points/s, against
    the 4.56 G points/s a 60 Hz re-shade of that accumulated cloud demands.
    The kernel's bill, presented rather than assumed.
15. **GPU shading.** The accumulated cloud resident in one shared Metal
    buffer, a compute re-shade and a full-cloud offscreen render measured
    over two layouts by the same probe: the 32-byte stride re-shades at
    3.4 G points/s — below the 4.56 G bill — and the packed split at
    18–19 G, four times over it; the padding decides, so the render buffer
    packs. The 60 Hz constraint moved to the draw itself — 17 ms per
    full-cloud pass — a bill that is measured and recorded, though no rung
    currently spends it; if an interactive viewer ever enters, the number
    is waiting. Confidence became color through one palette: low loud, high
    calm, undocumented values alarming, in an offscreen image a reader can
    open.
16. **Capture defaults.** The A–D matrix — stride, JPEG quality, depth
    codec — scored against the registered drop criterion: at or below 1%
    of callbacks, boundary-only. Cell A (stride 1) dropped 34.15%, chronic
    and interior; cell C (stride 2, HEIC) dropped 22.89%, HEIC's own
    53.31 ms encode mean exceeding the 33.33 ms keep budget stride 2 buys
    outright. Cells B and D (stride 2, JPEG) both passed, and JPEG 0.5 cut
    bytes 32.8% at no cost to the frame budget over 0.7, so the defaults
    became stride 2, JPEG 0.5, depth LZFSE.
17. **The movie path, behind a knob.** `VideoStoragePolicy` routes kept
    frames to `AVAssetWriter` as `video.mov` — HEVC, reordering off, movie
    and input pinned to one nanosecond timescale, the session started at
    `.zero`, fragmented output behind the knob. Every sample is stamped by
    the same pure function `StorageProbe` seeks and verifies with,
    frame-exact by equality and never nearest-neighbour. Built and gated;
    every number waited on the walks.
18. **The storage default.** Five cells — two movie walks, a dual-write
    walk and two desk kills — scored the movie path against per-frame
    files: drops at or below 1%, byte cut ≥20%, warm sequential ≤2×
    files, cold seek ≤100 ms. Identical frames cut −46.7%
    (68.3 → 36.4 KiB/frame); the scene bracket ran −46.7% to −72.9/−73.0%;
    warm replay came back 6× faster. A fragmented kill recovered 423 of
    445 kept frames through the last closed fragment boundary; the same
    kill unfragmented left 16,131,338 bytes on disk and nothing
    recoverable — no moov, zero tracks. The rule resolved without
    discretion: the harness defaults to `.movieTrack(fragmentInterval: 1)`,
    per-frame files behind the knob.
19. **Cross-frame reprojection, behind a probe.** The observable that needs
    no ground truth: a depth pixel of frame i unprojects through pose i,
    projects into frame i+k through pose i+k, and predicted depth is
    compared against what the sensor reported there. `Calibration` carries
    the analysis, `CalibrationProbe` replays it — Δ binned by confidence
    class, depth band and frame gap, ten registered filters and three
    sensitivity variants. Built and gated; every number waited on the
    replays.
20. **The calibration.** The confidence classes, measured in meters: high
    class disagrees with itself 3.1–10.8 mm across depth bands, low class
    18.9–197.2 mm, ordering held in 16 of 16 band comparisons with margin —
    including with the edge mask and the class match each turned off. A
    high-class drift slope of roughly 16 mm per second of separation is
    recorded without a verdict, no principled threshold existing yet; the
    low-class drift number is refused outright, the probe's own truncation
    bound flagging it as unmeasurable rather than small.
21. **The interop seam.** Two candidate seams, both built and both build
    jobs run before any library code existed: direct C++ interop
    (`.interoperabilityMode(.Cxx)`) builds and its own tests pass, but a
    client importing only the Swift module in front of it fails — `error:
    'string' file not found` — because every importer rebuilds the C++
    target's clang module in its own language mode, and `internal import`
    hides the API, not the mode, on Swift 6.3.3 / Xcode 26.6. The chosen
    seam is a pure C header over the C++ parser instead, so no importer of
    `Interop`, present or future, carries C++ interop forward. The attach
    line's "fills Core from a point-cloud file" could not be honored
    literally — `Core` has no point type, and changing its shape to gain one
    breaks the standing rule — so imported points land in `Interop`'s own
    `PLYFile`/`Element`/`Property` types instead, attached to the module
    graph nowhere.
22. **The reader, measured.** The four containers v0.4's calibration already
    used were dumped through `InteropProbe --dump` and each dumped PLY read
    back twice with `/usr/bin/time -l .build/release/InteropProbe
    <file.ply>`, the built binary invoked directly rather than through
    `swift run`. Across the eight reads: 2908.2–4465.0 ms, 124.6–189.8 MB/s,
    9.6–14.6 M points/s, and peak RSS running 9.2–12.1× the file each read —
    two full in-memory materializations of a `double`-widened representation
    on top of the whole file first read into one buffer, the architecture's
    bill rather than a leak. The README capture's dump reproduced the
    accumulated-cloud count the "README image" entry already recorded,
    independently: 44,973,892 points. Every deterministic block — encoding,
    byte count, layout, vertex count — byte-reproduced across each
    container's two reads; timing and memory did not, and are reported as
    the pair each run printed, never averaged into one number.
23. **List values, retained.** Closes the interop seam's deferral, forced by
    the rung's own charter rather than v0.6's: v0.6 consumes only vertex
    positions and confidence, already fully retained, so an offline fit
    gives it no reason to force this. What forces it instead is "a format
    with dozens of properties per point is the wrong job for Swift" — a list
    property's per-instance layout is exactly that job, and the walk already
    crossed every list entry before this commit without keeping anything.
    The seam commit's "decoded ... but not retained" was only ever true of
    the ASCII path; the binary path never decoded a single list value, only
    skipped past each entry by `count * valueSize`. Both paths now decode
    and retain, crossing as one flattened `[Double]` column per list
    property rather than nested per instance — the same shape scalar columns
    already cross in, so the ratio the previous commit measured is
    unchanged, only the bytes retained for properties that were previously
    free.

## Decided but not yet done

A list that only shrinks. Anything finished moves to *What has shipped* above
rather than gaining a tick here, so this section is empty when there is nothing
outstanding — which is the honest resting state, not a gap.

```text
  v0.6 fit is a rung, not a commit list. Nothing below this line is
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
| **v0.6** fit | Offline fit of the uncertainty model from replayed sessions | The model is *fitted*, not measured. Fitting is numpy's job, and it is what closes the thesis |
| **v0.7** service | The fit becomes an endpoint; the client uploads a bundle and gets a model back | Once the fit exists offline, shipping it to the device is the only way it reaches a user |
| **v0.8** view | A small web dashboard over the same service | Nearly free once v0.7 exists. Drops entirely if v0.7 slips |

Note the chain from v0.6 down. Python does not enter because Python is popular —
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
