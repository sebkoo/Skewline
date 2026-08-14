# Roadmap

Three time-scales live in three places. This page is the middle one: what has
been built, what the next few commits are, and what each future rung is waiting
on. The [README](../README.md) has the ladder at a glance;
[`DEVLOG.md`](DEVLOG.md) has what actually happened, including the mistakes.

Each rung is entered only when the previous one runs. The test every rung has to
pass: **does the rung below force this, or would it merely look good here?** If
it is the second, it does not go in.

## The shape of it

Seven modules. The graph is acyclic with `Core` at the root, and it is enforced
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

Model       done      the fitted model, read from the service and
                      evaluated locally. Depends on nothing above and
                      owns its value types -- joining a model to
                      rendered points is the consumer's edge, so it
                      never reaches for Render's.
 │
 └─ Sight   done      that consumer's edge, built: one depth sample and
                      the class the sensor gave it, into what the model
                      says about that point. Depends on Model alone --
                      the sensor's confidence integers are an encoding
                      the artifact never mentions, which is why they
                      stay out of the reader above.
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
v0.9  Sight      one tapped point's depth and class, into what Model says
```

Nothing above v0.2 touches `Core`'s shape. If a later rung needs `Core` to
change, that is a signal the boundary was drawn wrong, and it belongs in
[`DEVLOG.md`](DEVLOG.md) before it belongs in a diff.

## What has shipped

Thirty-five steps. The decisions behind each are in [`DEVLOG.md`](DEVLOG.md),
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
24. **The fit's data seam and the criteria before the data.**
    `Calibration.analyze` gained an additive `observationSink`, firing only
    where a sample survives all ten registered filters and lands in the
    default buckets, held there by three tests (conservation, observation-
    only equivalence, the occlusion fixture emitting nothing); the
    decimated, deterministic `--dump-observations` export; Python entering
    the repo in `Fit/` — `fit.py` and a sixteen-test `unittest` harness,
    numpy the only dependency, seeded, including per-form synthetic
    recovery; a fourth CI job running those tests; and, registered before
    any observation file existed, the fit's candidates (the incumbent
    table, affine, quadratic, power law), the leave-one-out split, the
    pinball-loss metric, the unanimous-across-folds adoption bar, and the
    refusal outcome for any class that fails to clear it.
25. **The fit the observations measured.** Low and medium classes each
    adopted a quadratic form (`a + b·d²` — low `a=0.022173, b=0.011175`,
    medium `a=0.010529, b=0.002781`) that beat the table in all four
    leave-one-out folds; every candidate for the high class lost at least
    one fold, by margins small enough that the held-out container flips
    their sign — exactly the case the unanimity bar exists to refuse
    rather than average away — so high keeps the table, refit on all four
    containers pooled. A consistency check found the decimated export's
    own upper medians within 0.00005 of v0.4's full-population figures,
    across all four containers. `Fit/model.json` — per-class verdict,
    coefficients, fold metrics, no raw observation — entered the
    repository under the standing aggregates-yes/raw-or-reconstructable-
    never line the calibration medians and the README capture had already
    cleared.
26. **The service seam, and the privacy line a wire forces.**
    `Fit/serve.py`: `GET /v1/model` returns the `skewline-fit/1` artifact,
    read through `fit.py`'s own reader rather than a second parser of the
    same schema, validated before it is served rather than proxied, and
    byte-identical to what `write_artifact` wrote. stdlib `http.server`, no
    dependency added — numpy arrives transitively through that reader — and
    the registered move-out condition if serving ever needs a third-party
    one. The wire runs one way, and this commit corrects the next-table line
    that promised a bundle upload rather than rewording it: at n=1 an upload
    is not merely a privacy cost but *unsupported*, because the registered
    procedure fits by leave-one-out across containers and one client's
    bundle has no fold and no holdout. The refusal is enforced by the router
    rather than promised — every method but GET and HEAD answers 405, no
    route reads a request body, and there is no per-point query surface,
    because "what is σ̂ at depth d" would send the *client's* depths up.
    Fifteen tests, one shown red first: allowing POST through the router
    served the artifact on an upload method (200 where 405 was expected).
    Registered for the Swift client that has not shipped: a new module on
    Interop's precedent, with both of v0.6's teeth unavoidable in the type —
    the refused class *and* out-of-domain refusal.

27. **The client the service registered.** `Model`: the `skewline-fit/1`
    artifact as Swift values, the schema tag checked before any other field
    is believed, and both of v0.6's teeth unavoidable in the type — a refused
    class is an enum case carrying the banded table it kept, so it still
    answers and there is no path from it to coefficients that do not exist,
    while outside the fitted depths every class refuses. The two silences are
    different cases, because "no form was adopted" and "nothing answers here"
    are different findings. The estimand rides the API: what comes back is
    named for the pairwise disagreement it measures, never `sigma`. The
    socket lives in one function and every decision beside it is pure, the
    split `serve.py` already made, so no test in the suite opens a
    connection. Forty-three tests, and the committed `Fit/model.json` is
    decoded by the suite through its own source path rather than copied into
    `Tests/`, where the copy would drift.
28. **The page the service renders, and the reader that does not exist.** A
    second route, `GET /`, serving an HTML document the service renders
    itself. The rung opened on the premise that a page evaluating the model
    is a *third* independent implementation of one schema — after the Python
    that writes it and the Swift that reads it — and that premise was
    discarded whole rather than solved: the same service renders the page
    through `fit.read_artifact` and hands the browser a finished document, so
    there is no third reader to hold honest, no node job, no toolchain pin
    and no sixth gate command. It sits off the version prefix because
    `skewline-fit/1` versions the payload and `/v1/` versions the endpoint
    set and the error shape, while an HTML document has no payload version to
    promise stability for — and `/` keeps `/v1/` a set of exactly one
    endpoint. `view.py` is a pure function of the artifact and the committed
    `view.html` shell, never receiving the request object at all, and both
    files are re-read per request. Errors on the page's route stay in the
    `/v1/` JSON shape, because one service is one error shape, with a new 500
    `no-view` for a missing shell: a committed document's absence is a broken
    checkout, the operator's problem rather than the request's. One clause of
    the privacy line acquired an exception — the page is the first consumer
    here that does not evaluate locally — and what makes that safe is the
    clause worth carrying forward instead: **no depth a client picked ever
    travels up.** A depth slider is therefore impossible by construction
    rather than merely unbuilt, needing either script in the browser or a
    query parameter, and `/?depth=2.0` answers 404 with the depth it refused
    named in the detail. Twenty-five tests, both teeth shown red first; the
    rendered page is 11,177 bytes for the committed artifact.
29. **The refuser, the registered ladder, and the evaluated column.** The page
    evaluates now, and the two things it needed first were a ladder that was
    actually registered and a refuser that is not `predict`.
    `ModelProbe.depths` was commented "the registered ladder" while the log
    said plainly that it was a probe-local choice registered nowhere; the log
    was right by this repository's meaning of the word, so the fix was to
    register it rather than to soften the comment. `fit.DEPTH_LADDER` is the
    declaration, `view.py` imports it, Swift carries the same eight numbers
    because it cannot read a Python constant, and the Python suite reads that
    declaration back out of the Swift file and pins the two equal — one source
    and one mirror, because a symmetric pair of literals has no owner. The
    ladder straddles both edges of the domain, so one output shows what
    answers and what refuses. `fit.predict` is a shared evaluator and
    deliberately not a shared refuser: it answers at 6.0 m where the Swift
    reader refuses, and its table path returns one `NaN` for two findings that
    type keeps apart. So `fit.estimate` mirrors `Estimate` case for case, four
    cases and no fifth, and it lives beside the declaration it enforces — which
    put two domains over one pair of endpoints inside one module, named apart
    so the difference is visible: `POSITIVITY_GRID` closed, asking whether a
    candidate may be adopted, and `ANSWERING_DOMAIN` half-open, asking whether
    a consumer gets a number, with a test pinning 5.0 m answering on the grid
    and refused by the refuser. Each class now carries an evaluated column at
    those eight depths, so a refused class visibly still answers from the table
    it kept, and every class refuses outside the domain — worded as the
    domain's refusal rather than any one class's, because those two silences
    are different findings. Holdouts print their first identifier block, after
    the fold table's `quadratic` column — the adopted form, whose margin is the
    evidence this rung gives a sign on purpose — was found falling off the card
    at the default width by eye, not by a test. Fifteen more tests; Swift
    unchanged, because the only Swift edit is a comment.

30. **The sighted point, and the span it refuses.** `Sight`, the seventh
    module: one depth sample and the sensor's own 0/1/2 class become what the
    model says about that point, and the join lives where `swift test` can
    reach it rather than in a screen. `Sighting` nests `Estimate` instead of
    flattening five outcomes into one, because the two silences a sensor makes
    happen before the model is consulted and the two the model makes are its
    own — four different reasons to have no number. Depth is checked before
    class, since a pixel with no return has no reading for a class to describe.
    `DepthMapGrid` does the half of a tap that can be wrong quietly: half-open
    on both axes and truncating, the convention the depth domain and the bands
    already use, with a clamp that makes the rule true of the *result* and not
    only of the input. The span is refused and the refusal is documentary —
    turning two per-point disagreements into an interval on their separation
    needs a propagation rule never derived here and a correlation between two
    points' errors that no export this repository produces could measure.
    `SightProbe` is this rung with the phone taken out.
31. **The interface the operator names.** A phone cannot reach a loopback
    socket on a laptop, so `Fit/serve.py` gained `--host`, in the same
    hand-rolled loop `--port` lives in and with the same shape: the safe value
    is what an operator gets for saying nothing, and reaching the network costs
    an explicit act that warns on every run. v0.7's decision survives intact
    because the flag does not move the default. What lost was shipping the
    artifact inside the app bundle — it builds and it lies, since the phone
    would read a copy rather than consume the API and `unreachable` would be a
    silence no client could reach. Four texts asserted the old unconditional
    fact and **none of them is covered by a drift assertion**, so naming them
    as a set was worth more than fixing them one at a time. The bind-host test
    was renamed rather than deleted and gained a sibling that drives the parse,
    making opt-in mechanical instead of promised. A wildcard bind now says the
    printed URL is not one a client can use, rather than printing
    `http://0.0.0.0:PORT` and looking helpful; no address is discovered to fill
    the gap, because choosing an interface for the operator is the default the
    flag exists to avoid.
32. **One sentence, two readers.** The registered wording lived on a `@main`
    struct, so a screen could not import it and copying was the only way to
    have it. Copied words drift exactly as copied schemas do, and worse: a
    refusal worded two ways is two findings to a reader who meets both, with
    nothing going red. It moved to `Sight` and `Model`, each beside the type it
    describes. The move found what hid behind it — as static functions on an
    executable target the wording had **never been tested at all**. Eight tests
    arrived with it, two of them properties rather than strings: every branch
    carrying a number must name the sessions it came from, and every refusal
    kind must have its own non-empty name, so a fourteenth kind added without
    one goes red with nobody remembering to add a case.
33. **The scale belongs to the reader.** "Disagreed by about 0.004096 m" was
    two claims that cannot both hold — either the digits matter and the hedge
    is noise, or a person is reading it and the digits are. One sentence, a
    precision the caller states, and no default: a default is how a screen ends
    up printing the machine's scale because nobody chose, and making it
    required turned the change into eight compile errors instead of eight
    silent string mismatches. The boundary test then found a real bug: the
    guard against printing "0 mm" ran on the raw value while `%.0f` rounds half
    to even, so exactly 0.5 mm cleared the guard and printed the reading the
    guard exists to prevent. The guard moved onto the rounded value — the same
    correction `DepthMapGrid`'s clamp makes, a rule about output enforced on
    the output.
34. **The frame the phone read.** `SightProbe --frame N` names a frame by its
    index instead of taking the first one carrying both maps. The default's
    rule is untouched and its reason still holds — picking the frame that
    answers best would be picking the finding — while naming one is the
    opposite act, an operator repeating a measurement rather than shopping for
    one. The report says which of the two happened. Three refusals stay apart:
    a container with nothing to sight, an index the container does not have,
    and a frame that exists and carries no maps. No unit test, and the reason
    is structural rather than an omission: an `executableTarget` with `@main`
    cannot be imported by the test target, and no probe here has ever had one.
    It was verified by running against a synthetic four-frame container that
    stayed in the scratchpad, the call v0.8 made about its capture driver.
35. **The point you tap, and the run that closed the rung.** The harness gained
    passthrough over the session it already owns — `ARView.session` has a
    setter, and `automaticallyConfigureSession` is set false because otherwise
    it reconfigures that session and drops the `.sceneDepth` semantic with
    nothing going red. The tap reads the frame the drain **wrote**, never
    `arSession.currentFrame`: the source strides and drops, so the frame on
    screen is often one no container will ever hold, and a reading taken from
    it could never be checked. The slot holds tight-packed bytes the depth
    encode already produced and discarded, so nothing retains an ARKit buffer
    and `DepthMapGrid`'s packed index is valid by construction rather than on
    the devices whose row stride happens to equal `width * 4`. Nine row states,
    none collapsing into another; unreachable and permission-denied are
    deliberately one, because iOS publishes no way to tell them apart and the
    preflight that exists raises the very prompt it would check. **No App
    Transport Security key ships**: the run fetched over the LAN to a numeric
    private address with none, and needed none — the key covers named hosts,
    not numeric IP loads, so shipping it would have registered a constraint
    that is not real and no run could have contradicted it. The rung closed on
    the pair its condition named, registered before the data: the phone read
    `about 4 mm` at frame 1296 and `SightProbe --frame 1296` read
    `0.004096 m` at the same pixel, one number at the two scales step 33 split.
    Six of the nine row states were not reached by that run and are written as
    a gap rather than a moved bar.

## Decided but not yet done

A list that only shrinks. Anything finished moves to *What has shipped* above
rather than gaining a tick here, so this section is empty when there is nothing
outstanding — which is the honest resting state, not a gap. It is empty now.

The divider went when v0.8 closed and came back when v0.9 opened. It is gone
again, and for the reason it went the first time: there is no rung below it to
name, and rewording it onto one that does not exist would be the invention this
repository refuses. It returns with the next rung, if a next rung is forced.

What each commit contains is decided by what the one before it turned out to be
wrong about. That is why [`DEVLOG.md`](DEVLOG.md) records the mistakes and not
only the decisions — it is the input to the next commit rather than a diary.
Commit 2's shape came out of commit 1's report; commit 5 exists because commit 2
discovered that `canImport(ARKit)` is true on macOS.

## What is next, and what forces it

| Version | Ships | What forces it |
|---|---|---|

The table is empty and the ladder above it has ended — every rung marked done.
That is a state and not a gap, and it is the second time this section has been
in it: v0.8's close emptied the table, v0.9 refilled it because the rung below
pulled one in, and it is empty again now for the reason it was the first time. A
row returns when something forces one, never because the section looks bare.
Python entered in v0.6 because an uncertainty model had to be fitted somewhere;
step 25 is that fit, steps 26 to 29 are the seam and the page that carry it to a
laptop's reader, and steps 30 to 35 put the same artifact in the hand of somebody
pointing a sensor at a room. What the chain ends with is a number on a phone that
a Mac re-derives from the container the same run wrote. It answers about one
point and refuses a span, for reasons kept in *Deliberately not built* rather
than in a screen's source.

What stays unmeasured is unchanged and stays written as a condition rather than
a plan: request latency, throughput, behavior under concurrent requests, the
per-request read-and-render cost and startup.
**They are measured when the service is run for a reader on a machine that
reader does not operate — the first moment a figure describes an experience
rather than a loopback round trip — and a registered workload exists to measure
against, so the number is reproducible rather than one anecdote.** Before both,
a millisecond from a local GET is decoration. **The first half has now
happened** — v0.9's by-hand run served the model to a phone from a laptop that
phone's reader does not operate — and the second has not: no workload is
registered, so there is nothing for a number to be reproducible against. The
trigger stands untripped on its remaining half, and no number here is owed one
yet. That trigger and the three in *Deliberately not built* are the only
registered conditions under which this table gains a further line, and none of
them is a promise that it will. That is the difference between a ladder and a
checklist.

## Deliberately not built

On-device inference, document scanning, and location services. None of them has
a job in an indoor spatial-capture pipeline today. The honest answer to "why is
this here?" would be embarrassing, and a reader can tell.

On-device inference has a written trigger rather than a plan: if the analytic
error model is **measured** to break down under some material or lighting
condition, that measurement justifies a learned component. Before the
measurement it is decoration.

Capture upload joined this list in v0.7, having previously been written into
the table above as something v0.7 would ship. It is not deferred for privacy
alone — at n=1 it is unsupported. The registered procedure fits each class by
leave-one-out across containers and adopts only on a unanimous sweep of the
folds, so one client's bundle has no fold and no holdout, and an upload
endpoint would have to run criteria that do not exist. That is precisely what
v0.6 spent a rung refusing to do. The trigger, in the same shape: upload
revisits when a registered procedure exists that can fit or update a model
from a single client's data, **and** the wire's privacy line is decided for
that payload class. Before both, it is decoration with a privacy cost.

An interval on a distance joined this list in v0.9, before the rung had a screen
to put one on. A tape measure printing `1.42 m ± 0.03` is the obvious feature and
would be the largest overclaim in this project's history: the estimand is the
disagreement of **one point** at one depth, and turning two per-point
disagreements into an interval on their separation needs an error-propagation
rule that has never been derived here and a correlation between the two points'
errors that has never been measured. The trigger, in the same shape, and it has
two gates rather than one. First, that rule, derived and written down. Second, a
data seam that does not exist: `Calibration.Observation` carries a separation, a
Δt, a class, a depth and a residual, and **no frame identifier and no pixel
identity**, so two observations cannot be known to come from one frame pair — the
correlation is not computable from any export this repository has ever produced.
The export that could compute it carries per-pair per-pixel rows, much closer to
reconstructable than the aggregates the privacy line permits, so building it
needs a privacy decision before it needs code. Before all of that, a span
interval is a plausible number, which is worse than no number.

Unlike the refusals the router enforces, this one is documentary. A 404 is a
fact; here nothing stops a caller adding two of the module's own `Double`s
together. What enforces it is that no API takes two points and no surface offers
a span, and saying so plainly is better than implying a guard that is not there.

## Sequencing

Written at v0.1 and left verbatim while the ladder climbed past it: v0.1 was
days. v0.2 through v0.4 was where this became real or stalled, and nothing
below v0.4 was worth starting until a device was producing sessions that
replayed deterministically. If time ran short, stopping cleanly at v0.4 with
four things done properly beat eight things half-wired. It held — v0.4 shipped
clean, and the ladder kept climbing past it — so this stays as the record of
that call, not as live advice for the rungs still ahead.
