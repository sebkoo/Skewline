# DEVLOG

Decisions, the day they were made. The commit log says what changed; this says
why, and what I was unsure about.

## 2026-08-08 · commit 1 — pose and session types

Five files, no capture code. Testing one claim: a spatial result needs a
confidence beside it.

- **Pose and covariance in one struct.** Separable means some path drops one and
  the survivor still looks authoritative.
- **Four `SIMD4<Float>` columns, not `simd_float4x4`.** Apple ships no `Codable`
  for the simd matrices, so synthesis fails. Confirmed by compiling, not reading.
- **Explicit `Sendable` on every public type.** Load-bearing sooner than
  expected: `Transform4x4.identity` and `PoseCovariance6x6.zero` are
  `public static let`, and SE-0412 requires globals to be `Sendable`.
- **`Core` does not import ARKit.** `TrackingQuality` mirrors
  `ARCamera.TrackingState` by hand — keeps the boundary for commit 2 and the
  suite off a device framework.
- **Covariance layout is provisional.** Flat 36 `Double`, row-major, m²/rad².
  Quaternion tangent space likely once a model is fitted. Pose is `Float` and
  covariance `Double`; that asymmetry was not a decision.
- **Verified the test can fail.** Temporary encoder writing 36 zeros → red at
  the covariance expectation. Reverted. The round trip really does check that
  uncertainty survives.
- **Tests run on the Mac.** Xcode against an iPhone destination fails outright:
  tool-hosted test targets cannot use device destinations.
- **My brief said "no name in this commit"; `Package.swift` requires one.** It
  should have said "no brand". Package is `SpatialCapture`, targets unchanged.

## 2026-08-08 · commit 2 — the ingest boundary

Commit 1 claimed hardware-free testing with no hardware path to be independent
of. Now there is one.

- **`canImport(ARKit)` is true on macOS.** A stub ships in the SDK, so the import
  succeeds and `ARSession` is still missing. Gate became
  `#if canImport(ARKit) && os(iOS)`. Found by letting the build fail. `canImport`
  answers "can I import this", not "are the symbols here".
- **Protocol lives in `Capture`, not `Core`.** `Core` stays data-only and neither
  it nor `Replay` was touched. Wart: `Capture` needs `Replay` only for the
  `CaptureSession` type, which is arguably `Core` material — moving it reopens
  commit 1.
- **Pull, not push.** Concrete `AsyncThrowingStream` return rather than an
  associated type, so one non-generic consumer works against every conformer. If
  the consumer must know which source it holds, the boundary failed.
- **`.zero` covariance is a placeholder.** ARKit exposes no pose uncertainty. Not
  a claim that the error is zero.
- **`@unchecked Sendable` is honest, not proven.** `ARSessionDelegate` serialises
  callbacks; Swift cannot see that. A lock is the hardening if it needs one.
- **The iOS-only file is now type-checked.**
  `xcodebuild -destination 'generic/platform=iOS' build` succeeded — ARKit module
  loaded, `SensorSource.swift` compiled for `arm64-apple-ios18.0`. Still never
  run.
- **Commit 1's log paid for itself.** It flagged that `platforms:` named only
  iOS; `AsyncThrowingStream` needed `.macOS(.v13)`. Twenty seconds, not twenty
  minutes.

## 2026-08-08 · commits 3–4 — licence, and a test that was lying

- **Apache-2.0, not MIT.** Patent grant — the clause legal review looks for
  before approving an outside dependency.
- **The round trip skipped three fields.** Per-field assertions covered
  transform, covariance and tracking quality, never `timestamp`, `id` or
  `startDate`. Now `#expect(decoded == session)`. Reads like deleting
  assertions; actually widens coverage, so the reason lives in the code. Cost: a
  vaguer failure message.
- **A command block with a manual edit in the middle gets pasted whole.** The
  edit was skipped and the commit message promised two things while the diff
  held one. Same shape as `--amend` acting on whatever HEAD happens to be.
  Either the command performs the edit or the edit is not in the block.
- **`git show --stat` caught it; no hook could.** A `commit-msg` hook checks that
  a subject is imperative, short and prefixed. It cannot check whether the
  subject is *true* of the diff. Guardrails police form, and form is not
  accuracy — worth remembering when the hooks go in.

## 2026-08-09 · naming the package

- **`Skewline`.** Two back-projected rays should meet at the point and never
  do; they are skew lines, and the length of their common perpendicular is
  the residual. The name is the thesis.
- **A package `name:` is not a module name.** Targets are what `import` sees,
  so nothing references it. Expected a sweep across the tree; the rename is
  one line and no source files.
- **An unavailable GitHub org handle was never a blocker.** A solo repository
  lives under a personal account and never needs the bare namespace.
  Candidates died on a constraint that was invented, and it was mine.
- **A coined word is not automatically free.** The most invented-looking
  candidate is a trading company with a mark published for opposition.
  Novelty is a guess about the world, not a fact about it.

## 2026-08-09 · commit 5 — CI

- **`Skewline-Package` is the scheme that matters.** `xcodebuild -list` reports
  four — `Core`, `Replay`, `Capture`, and the SwiftPM-synthesised umbrella. Only
  the umbrella builds every product in one pass, which is what puts the
  ARKit-gated file in front of a compiler that has `os(iOS)` true.
- **The brief predicted the first push would fail. It did not.** `macos-26`,
  `/Applications/Xcode_26.6.app`, `checkout@v7` and the scheme name were all
  looked up rather than guessed. Looking things up is cheaper than a fix commit.
- **A pinned toolchain is an assumption until the log prints it.** One step
  running `xcodebuild -version && swift --version` reports Xcode 26.6, build
  17F113 — the same build as this machine. Without it a silently failed
  `xcode-select` is indistinguishable from a green run.
- **No cache, deliberately.** A precompiled module that remembered an absolute
  path it no longer lived at already broke a local build three commits ago. The
  whole run takes 38 seconds; there is nothing to optimise.
  
  ## 2026-08-09 · the permission rules

- **`git show --stat` and `git push` in one pasted block is not a check.** The
  stat printed one file where the message promised rules, but the paste had
  already run the push by the time anyone read it. A check downstream of the
  thing it guards is decoration.
- **`.gitignore` said `.claude/` and nobody looked.** `git add` refused the
  path, the commit succeeded anyway, and the message outlived its diff for the
  second time in this repository. An excluded parent cannot have a child
  re-included, so the fix is `.claude/*` with `!.claude/settings.json`.
- **The rules bind the agent, not the terminal.** `git commit --amend` is denied
  to the agent and still available here, which is the right split: the one time
  amend went wrong it was a human command run twice, and that is a human's
  problem to notice.

## 2026-08-09 · the first device capture

- **The first second of a capture is not a measurement.** ARKit reports
  identity translation while it initialises: 59 observations at exactly
  `[0,0,0]`, every one of them `limited(initializing)`, and not one `normal`
  observation there. Only the quality field separates a placeholder from a
  pose — the thing this package claims and had never demonstrated.
- **Nothing was dropped.** 3,026 frame gaps, total spread 1.251 microseconds,
  none over 100 ms. Consuming the stream in a detached task and writing once
  at stop is what bought that; a write on the delegate queue would have looked
  like a tracking problem rather than an I/O one.
- **The origin is read at `run()`, not at the first frame.** That frame arrives
  750, 440 and 376 ms later across three launches, so the rejected alternative
  would have put any earlier sample that far below zero — silently, and only
  once a second sensor existed to notice.
- **Twenty-three per cent of the file is zeros meaning `not measured yet`.**
  108,972 of them. The `TODO(owner):` on covariance is not a small one.
- **A command written into `CLAUDE.md` had never been run as written.** The iOS
  build needs `-scheme Skewline-Package`. Same shape as the `.gitignore`
  misses: a documented claim nobody had executed.

## 2026-08-10 · a second sensor on the same clock

- **ARKit and Core Motion share a monotonic base. Measured, not assumed.**
  Against one origin: inertial t0 +0.009 s, pose t0 +0.444 s — 5,107 samples
  beside 3,052 poses, both sequences non-negative. The 435 ms ARKit spends
  before its first frame is no longer unwitnessed.
- **The 200 Hz request came back as 99.45 Hz.** The believed ceiling is real
  and now has a number: delivered interval 10.055 ms. The sensor's own stamps
  are as tight as the camera's — 3.292 µs of spread across 5,106 gaps, none
  over 100 ms. Burstiness lives in delivery, not in the timestamps.
- **The tracker said `normal` at 27.5 rad/s.** A deliberate pan and a 10.1 g
  shake never fired `limited(excessiveMotion)`; the only `limited` after
  init was `insufficientFeatures` — the scene, not the motion. Tracking state
  does not encode motion, which is the sentence this commit exists to say
  with data rather than as a premise.
- **`NSMotionUsageDescription` proved unnecessary.** No key in the plist, and
  nothing died at `startDeviceMotionUpdates`. The defensive key would have
  been an unexercised claim; the device run made its absence a recorded fact.
- **A motion error fails the whole capture.** `SensorSource` keeps the pose
  stream alive when Core Motion errors; the harness joins both drains in one
  `do`, so either sensor failing writes no file. The brief decided the source's
  policy and never the harness's. Kept, now as a decision rather than an
  accident: a file that looks whole while missing a sequence is worse than a
  loud failure.
- **"Quoted in the doc comments" became paraphrase.** The units are the
  headers' — radians per second, G's, the right-hand rule — but nothing is
  quoted verbatim. Recorded because a quote and a recollection are different
  claims, and the difference is one this repository keeps insisting on.
- **`deviceMotionRate` is public API the plan never named.** The 200 Hz probe
  needed somewhere for its rationale to live; a named `public static let` is
  where the doc comment went. One symbol of surface outside the plan's manifest.

## 2026-08-10 · commit 3 — camera frames and the container

- **The copy did not dent the load-bearing queue.** 1,849 poses at 59.976 Hz,
  spread 1.876 µs, none over 100 ms — the same shape as before the copy
  existed, re-measured rather than assumed.
- **The accounting closed twice.** 1,793 kept + 56 dropped + 0 strided =
  1,849 callbacks — first from the file's holes, then from the source's own
  counters. Disjoint by construction, or the next bullet could not exist.
- **The 56 losses are three stories.** 31 in one 533 ms hole: encoder cold
  start, confirmed — encode max 651.44 ms, and the hole opens exactly
  bufferDepth × one frame-time after the first kept frame. 14 at t=5.44:
  open — a sub-max stall the panel cannot separate from a disk or scheduler
  pause. 11 across nine micro-holes, then zero drops for the last ten
  seconds including a 24.4 rad/s pan.
- **Steady state fits the frame budget.** Encode mean 14.53 ms against
  16.67; payload 269.9 MB at a mean 154 KB/frame (JPEG 0.7, 1920×1440,
  stride 1). v0.4's knobs start from these numbers.
- **Every frame timestamp is a member of the pose set.** Zero mismatches in
  1,793 — same-`ARFrame` identity, now a property of a file.
- **No third protocol, deliberately.** One honest conformer, and its element
  type would decide where encoding lives — v0.4's question. The boundary
  gets drawn in v0.3 when the renderer makes a second consumer real.
- **The planned failure injection could not fail.** Writer and reader share
  the naming function, so breaking it breaks both. Skewed the reader
  instead; red at a missing file.
- **The app target defaults to `MainActor`; the package does not.** Found by
  the harness build failing after the package built clean — the gap that
  made the harness build part of the gate.
- **Commit 2's numbers reproduced.** 99.45 Hz (10.055 ms); `normal` through
  24.4 rad/s; `insufficientFeatures` still the scene, not the motion;
  warm-up 534 ms, inside 376–750.

## 2026-08-10 · commit 4 — depth enters the container

- **The fork answered after the build, not before it.** The brief made
  `supportsFrameSemantics(.sceneDepth)` the gate; the connected phone's model
  was LiDAR-class, so the depth path was built on that evidence and the call's
  answer — `supported` — arrived with the probe run. Right on this phone,
  and still a bet where the brief had ordered a measurement.
- **LiDAR has its own warm-up, and it is indexed.** The 10 depth-less frames
  are exactly indices 0–9, t=0.604–0.788 — about 184 ms after ARKit's first
  frame. `sceneDepth`'s nullability is a state that occurs, not defensiveness.
- **Every depth map is 256×192 'fdep' float32, every confidence 'L008'
  uint8** — 2,382 of each, observed where the headers promise nothing. LZFSE
  pays for itself five times over: 558.3 MB packed → 111.4 MB written, ratio
  0.20, mean 48 KB/frame beside the 197 KB JPEG. v0.4's raw-vs-lzfse question
  now has one side measured.
- **A third of depth pixels are less than fully trusted by their own
  sensor.** low 14.8% / medium 21.1% / high 64.1%. The thesis in miniature:
  the map alone would look uniformly authoritative.
- **The frame budget broke, and the drops say how.** Encode 15.50 + 5.74 =
  21.2 ms against 16.67; the 1,200 drops are chronic — kept-frame gaps
  {1:1277, 2:1077, 3:26, ≥4:11} — not stalls. Drain period 59.87 s / 2,392 =
  25.0 ms/frame, and the ~3.8 ms between the encode sum and the period is
  append plus overhead that nothing clocks separately — t=5.44's lesson,
  repeated. At stride 2 the candidate period is 33.3 ms and the drain fits
  with margin: v0.4's knob data, not this commit's decision.
- **The pose baseline held through the new ARKit work and the double copy.**
  59.976 Hz, spread 1.37 µs — tightest yet — max 16.674 ms, none over 100 ms.
  Re-measured rather than assumed, because "no regression" is a claim about
  code that no longer exists. Identity: 0 of 2,392 frame timestamps outside
  the pose set. The accounting closed twice again: 2,392 + 1,200 + 0 = 3,592
  from the file's holes and from the counters.
- **`excessiveMotion` finally fired — at 1.28 rad/s.** Twelve observations,
  immediately after a 5.9 s `insufficientFeatures` stretch, while the run's
  23.32 rad/s maximum stayed `normal`. The label anti-correlates with
  measured motion in both directions in this capture; commit 2's sentence
  now has its converse.
- **A count check would have blessed misplaced holes.** Depth is optional per
  frame, so payload-count equality no longer implies position equality;
  `finalize` checks the per-index biconditional, and the test that keeps it
  honest appends the one payload at the wrong index and expects red.
- **`PixelBufferPacking` is public surface the brief never named.** The
  tight-pack loop sits in `Capture` outside the ARKit gate so the Mac suite
  can prove it against a padded buffer with poisoned padding — the
  alternative left the shear-prone loop in the one component `swift test`
  never compiles.
- **The roadmap said "ImageIO depth".** Depth shipped as ARKit `sceneDepth`
  payloads in the container instead; the row now says what happened.

## 2026-08-10 · the drift check

- **The check arrived before the truth it enforces.** Two commits, one push:
  `ci:` adds the `readme-drift` job, the `docs:` commit after it brings the
  README true. CI runs on the pushed head, so history shows the enforcement
  predating the fix without a red push.
- **Both reds were observed, not assumed.** Against the pre-fix README:
  `README claims "No app" -- an app project exists at
  App/SkewlineHarness/SkewlineHarness.xcodeproj` and `README claims "Two CI
  jobs" -- ci.yml defines 3: test, build-ios, readme-drift`. The second is
  the check catching its own introduction — adding the job falsified the
  count, and the demonstration cost nothing.
- **Negative claims retire on removal; anchors may not.** "No app" is probed
  only while its text appears verbatim, so deleting the claim is the whole
  fix. The ladder, the module list and the job-count sentence are required —
  a check that silently skips when its anchor vanishes is decoration, the
  commit-msg-hook lesson applied to the new hook itself.
- **Verbatim matching cuts both ways, and the fix found the edge.** Moving
  "no rendering" to a sentence start would capitalise it and quietly retire
  the lowercase probe; the corrected README keeps the claim mid-sentence.
  Found by writing the fix, not by writing the check.
- **Agreement is not truth.** The ladder assertion compares the README to the
  ROADMAP's table; both being wrong together passes. And the ROADMAP's own
  shape block still calls v0.2 "sensors" where its table says "capture" — an
  internal seam no assertion reads.

## 2026-08-10 · commit 5 — exposure enters the frame record

Off-device analysis of the bright/dim/pan capture: 2,469 poses, 4,149
inertial samples, 1,669 frames over 41.2 s.

- **Exposure landed on every frame.** 1,669 of 1,669 encoded frames carry an
  `ExposureRecord`; the container's file and the run's panel agree exactly.
  Duration is quantized, not continuous: 16.67 ms (1,418 — the 60 fps
  ceiling), 16.39 ms (242), 8.33 ms (9); mean 16.58 ms. Most of the run sat
  dim-pinned at the ceiling.
- **The bright/dim design worked.** Offset traversed −6.52 EV (t=22.9 s) to
  +1.36 EV (t=40.3 s) — a 7.9 EV swing across the capture.
- **The first blur product, measured.** Duration × angular velocity peaked
  at 0.523 rad — thirty degrees of rotation inside one exposure — at
  t=27.2 s, where the run's highest rotation rate yet, 31.37 rad/s, met the
  exposure ceiling. The tracking-quality label there was
  `limited(insufficientFeatures)`, not `excessiveMotion`.
- **The label family stayed scene-conditioned, a third time.** 163
  `excessiveMotion` observations clustered in the dim section (t=21.7–41.0 s,
  ≤18.13 rad/s), while the run's fastest rotation, 31.37 rad/s, drew
  `insufficientFeatures` instead. Commit 4's finding gets richer, not
  reversed: the label still tracks the scene, not the motion.
- **The pose baseline held mid-run.** 2,467 interior gaps, 16.6726 ms /
  16.6734 ms min/median, microsecond spread, none over 100 ms. Reading two
  scalars off `ARCamera` per frame cost nothing this baseline could detect.
- **Both stop races fired, and both are boundary artifacts, not bugs.** The
  one 33.35 ms pose gap sits at the very end — `pause()` swallowing the
  session's last camera frame. Poses (2,469) outrunning the frame path's
  callback count (2,468) by one is the `.terminated`/`.off` case
  `cameraFrames()`'s doc comment excluded from the accounting invariant back
  at commit 3: predicted there, observed here.
- **Drops reproduced the chronic pattern, not a stall.** 799 of 2,468
  callbacks dropped (32.4%), shaped {1: 944, 2: 694} plus one 29-frame
  cold-start hole matching a 459.00 ms encode max. Budget economics
  unchanged: 15.56 + 5.38 = 20.9 ms against a 16.67 ms frame.
- **Depth reproduced too.** 1,657 with depth + 12 warm-up frames without,
  ratio 0.18, formats 'fdep'/'L008' as before. Identity held: 0 of 1,669
  frame timestamps outside the pose set. Warm-up 537.7 ms, inside the
  376–750 ms range commit 4 established.
- **The confidence tally summed to 100.1%, not 100%.** Rounding across three
  percentages, not a counting error — worth the one word so a future reader
  does not go looking for the missing tenth.

## 2026-08-10 · v0.3 commit 1 — the operand v0.2 never recorded

Not a v0.3 commit in the sense the roadmap means it — no Metal, no render
module, no unprojection arithmetic. v0.3's first arithmetic is unprojection,
depth pixel → camera ray → world point, via pose and intrinsics; `FrameRecord`
carried pose and depth and never intrinsics. The ROADMAP's own rule caught it:
*"Nothing above v0.2 touches Core's shape. If a later rung needs Core to
change, that is a signal the boundary was drawn wrong."* v0.2 called itself
done at twelve steps while missing an operand its own successor needs. This
commit is that correction, and the lesson is worth more than the diff: closing
a rung does not mean the rung's outputs are complete, only that its own tests
pass.

- **Four scalars, not the matrix — and checked, not assumed.**
  `ARCamera.intrinsics` is a pinhole matrix; only fx, fy, cx, cy vary per
  frame; the rest are the model's own constants. `IntrinsicsRecord` keeps the
  four. Compaction without a check would be a guess wearing a type, so
  `FrameEncoder` verifies the other five entries equal their expected
  constants before building the record and throws
  `unexpectedIntrinsicsShape` if they do not — the same split `DepthEncoder`
  already makes for pixel format, applied to a matrix shape instead of an
  `OSType`.
- **The reference resolution rides beside the four numbers, in `Core`.**
  `ARCamera.imageResolution` is the pixel resolution fx/fy/cx/cy are
  expressed at, and a resolution recorded nowhere is a scale nobody can
  recover. `IntrinsicsRecord.referenceWidth`/`referenceHeight` are not the
  same fact as `FrameRecord.width`/`height`: those describe the stored
  payload, this describes the frame the intrinsics were computed in. The two
  agree today only because the harness stores full-resolution JPEGs — a
  downscaled-storage knob later would separate them, and a record that
  borrowed its reference frame from the payload would drift silently the day
  it did.
- **`Capture` still knows nothing about the pinhole model.** `CameraFrame`
  carries the raw `simd_float3x3` and `CGSize`, the same undecomposed way it
  already carries `pixelBuffer` and `CapturedDepth`. Decomposition and the
  shape check live in `FrameEncoder`, in the harness app, not in `Capture` —
  `Capture`'s job stays shuttling SDK values across the ARKit boundary, never
  interpreting them.
- **The panel answers the open question without a new module.**
  `SessionRecorder`'s frame panel gains an `intrinsics` line: the min/max of
  fx, fy, cx and cy the run observed, and the reference resolutions seen. It
  exists to answer, from one capture, whether the four numbers hold constant
  through a run or move with focus and stabilization — a finding for the
  device run to make, not a premise to build on.
- **No new typed-absence API.** `FrameRecord.intrinsics == nil` already says
  "this frame cannot be unprojected" in a typed way; a convenience property
  saying the same thing would be surface with nothing forcing it yet.

## 2026-08-10 · the intrinsics probe

Off-device analysis of a 38.0 s capture: 2,282 poses, 3,847 inertial samples,
1,556 frames.

- **The four numbers move.** 1,378 distinct fx values across 1,556 frames —
  continuous focus breathing, not discrete steps. fx spans 1318.38–1410.21, a
  6.97% swing (minimum at t=1.5 s, maximum at t=38.0 s); cx moved 8.5 px and
  cy 13.0 px, tracking stabilization. Reference resolution held constant at
  1920×1440. A session-level intrinsics record would have carried up to 7%
  focal error into every unprojection, silently — the per-frame placement
  this commit chose by mirroring `ExposureRecord` is now a decision with a
  number behind it, not just a copied pattern.
- **fx equals fy exactly, on all 1,556 frames** (maximum observed difference
  0.000000): ARKit reports square pixels through one focal scalar on this
  device. A finding, not a premise the record assumed — `IntrinsicsRecord`
  rightly keeps both fields rather than compacting further on a guess.
- **The pinhole check held.** Zero `unexpectedIntrinsicsShape` across every
  one of the 1,556 frames the encoder saw; the fail-loud policy had nothing
  to fail loudly about, on this run.
- **Cleanest pose baseline of five runs.** Poses (2,282) equal frame-path
  callbacks (2,282) — both of commit 5's stop races stayed dormant this
  time, consistent with them being races rather than deterministic bugs.
  Interior gaps 16.6725 ms / 16.6734 ms / 16.6744 ms min/median/max, none
  over 100 ms, 59.976 Hz. The added per-frame matrix read cost nothing this
  baseline could detect.
- **Everything else reproduced.** Inertial 99.45 Hz; identity held, 0 of
  1,556 frame timestamps outside the pose set; depth 1,546 with + 10
  warm-up, ratio 0.19, formats 'fdep'/'L008' as before; exposure on every
  frame, ceiling-pinned (mean 16.65 ms), offset down to −6.52 EV; drops 726
  of 2,282 (31.8%), chronic {1: 888, 2: 644} plus one 33-frame cold-start
  hole matching encode max 523.55 ms.

## 2026-08-11 · v0.3 commit 2 — unprojection, on the CPU, measured

A fourth module, `Render`, and the rung's first arithmetic: depth pixel →
camera ray → world point, replayed over four exported containers (1.4 GB,
three with depth, one with intrinsics) by a `RenderProbe` executable — the
first analysis in this repository that can be re-run rather than
reconstructed.

- **The SDK's own words do not exist.** The brief ordered the depth
  convention verified against them before the math was written; ARKit's
  entire shipped text on `depthMap` is "per-pixel depth data (in meters)",
  and nothing in the headers picks planar z over ray distance. The deciding
  source is Apple's *Displaying a Point Cloud Using Scene Depth* sample,
  whose shader uses the depth value directly, unnormalized, as camera-space
  z. `constantDepthMapUnprojectsToConstantCameraZ` locks the choice: a
  constant map must unproject to exactly constant camera z, and a
  ray-distance reading fails it. One ambiguity stays recorded rather than
  resolved: whether the depth grid shares the reference grid's corner or its
  pixel centers is documented nowhere — at most half a depth pixel, about
  0.28% of the field angle.
- **The captures were not on this Mac.** The brief said they were; only the
  `session.json` manifests had been exported, and every payload byte was
  still on the phone. The full containers now live outside the repository at
  `~/dev/Skewline-captures` — captures, not source — and the probe takes
  paths as arguments.
- **Three honest zero rows.** Only 88ACAA6A carries intrinsics; the two
  older depth captures report `no-intrinsics 2382` and `no-intrinsics 1657`
  — 400 MB of real payload read end to end on the way to a typed absence —
  and the frames-only capture reports `no-depth 1793`. `no-pose 0` on all
  four: the frame-timestamp-in-pose-set identity, until now a device-side
  claim, reproduced through the Mac-side `Reader`.
- **75,988,992 points, exactly 1,546 × 49,152.** The skip path for invalid
  depth never fired: no zero, negative or non-finite sample in 76 M. Depth
  spans 0.035–24.766 m — the sensor reports far beyond its nominal range,
  it just says how little it believes itself out there.
- **44% of points are less than fully trusted by their own sensor.** low
  21.6% / medium 22.4% / high 56.0% — the depth-pixel finding of commit 4,
  now carried per point, which is the value this module exists to refuse to
  separate.
- **The bill: 57.8 M points/s cold, 200.0 M warm.** The first run — cold
  file cache, minutes after the export — measured 57.8 M points/s (total
  1.32 s, per-frame 0.24/0.69/2.10 ms min/median/max); a second operator's
  re-run minutes later measured 200.0 M (0.38 s, 0.20/0.24/0.68). The
  probe's own label calls the timing block not deterministic, and the
  range is the honest number. Conversion fits the 16.67 ms budget at
  either end; re-shading the accumulated cloud is what breaks: 76 M points
  at 60 Hz demands 4.56 G points/s, 79× to 23× above the measured range.
  The ROADMAP's sentence — the arithmetic forces the kernel — now has its
  number at both ends, and it is the accumulation, not the per-frame work,
  that does the forcing.
- **The deterministic block reproduced, byte for byte.** Two operators, two
  runs, one machine: every count, bound and tally identical — and the
  probe's re-tally of confidence from decompressed payloads matches the
  harness's capture-time panel exactly (21.6 / 22.4 / 56.0). The property
  v0.4's replay work stands on ran its first demonstration, and payload
  integrity gained a third, independent witness.
- **One capture's cloud is 2.43 GB at rest.** `ConfidencePoint` strides
  32 bytes, not 17: `SIMD3<Float>` is 16-byte aligned and the confidence
  byte pays 15 bytes of padding for riding beside it. Whether a render
  buffer keeps that layout is the kernel's decision, now with the cost on
  record.
- **The decoder round-trip was watched failing.** A deliberate ×2 mis-scale
  went red at the depth expectation and was reverted — the payload is built
  with the harness encoder's exact `compressed(using: .lzfse)` call, so the
  test inverts what the device writes, not a re-implementation of it.
- **Depth decode landed in `Replay`, against an old doc comment.** The
  container's "decoding is the consumer's job" was written about JPEG, whose
  decode drags an image framework; depth's inverse is Foundation-only byte
  arithmetic, and v0.4 will need it without importing `Render`. The comment
  now says what the split actually follows: imports, not ownership.
- **The executable built for the device unguarded.** The umbrella scheme
  compiled `RenderProbe` for `generic/platform=iOS` without the
  `#if os(macOS)` fallback the plan held in reserve — checked by the gate,
  not assumed.
- **"The four-command gate" is written down nowhere.** CLAUDE.md states two
  commands; the harness build survives only as a permission-file allowance
  and a DEVLOG sentence, the drift check only in CI. This run used all four;
  the doc gap is now on record.

## 2026-08-11 · v0.3 commit 3 — the cloud on the GPU, measured

The accumulated cloud in one `.storageModeShared` buffer, a compute re-shade
and a full-cloud offscreen render over two candidate layouts, measured by the
probe on the 75,988,992-point capture: 21 iterations per configuration, the
cold first printed apart from the warm rest, wall clock beside the device's
own interval, two runs.

- **The padding decides, not the arithmetic.** The 32-byte stride re-shades
  at 3.37 G points/s in both runs (3.40 by the GPU's clock) — below the
  4.56 G bill. The packed split — 12-byte positions beside bare confidence
  bytes — re-shades at 18.3–18.4 G wall, 19.2–19.4 gpu-clock: four times the
  bill, 5.4× past the same kernel over the padded stride, for byte-identical
  output. The render agrees at smaller scale: 4.42 G packed against
  3.39–3.46. The layout decision is pack, and it is a traffic decision —
  3.37 G × 36 B/point ≈ 121 GB/s against 18.4 G × 5 B ≈ 92 GB/s, both passes
  sitting near the memory system and nowhere near an ALU limit (derived
  from the measured rates, not measured separately).
- **The bill is paid — and the constraint moved.** Re-shading 76 M points
  costs a 4.1 ms median in the packed layout: the 4.56 G points/s demand
  that stood 79×–23× over the CPU is met with 4× headroom. What misses
  60 Hz is the draw: the full-cloud render's warm median is 17.2–17.3 ms
  packed, 20.7–20.9 padded, against the 16.67 ms frame — 4.42 G points/s
  where the bill says 4.56. Re-shading was never the binding constraint on
  a GPU; redrawing an unbounded accumulation is, and that is v0.4's
  frame-time problem stated with this commit's numbers.
- **The kernel is earned by change, not by shading.** A static-color cloud
  needs no compute pass per frame — the vertex stage shades at fetch cost;
  render and re-shade over the padded layout land at the same rate because
  both are bound by the same bytes. What the kernel buys, measured: re-map
  the entire cloud — a new palette, a threshold — in 4.1 ms, comfortably
  inside one frame. The ROADMAP's word "kernel" survives as a capability,
  not as the per-frame path.
- **xcodebuild claims a `.metal` file even declared `.copy`** — and Xcode
  26's Metal compiler is a separately downloaded toolchain this machine did
  not have, with CI's runners undocumented either way — while `swift build`
  copies the file verbatim under `.copy` and `.process` alike, observed in
  the built bundle. The shader therefore ships as `ConfidenceShaders.msl`,
  an extension no build system claims, compiled at runtime by the one code
  path every gate command and the test suite exercise. Cost, stated: no
  compile-time check against the iOS air target until an iOS consumer
  exists to run it.
- **The kernel and the CPU agree on every one of 76 M points.** The color
  tally read back from the kernel's output — low 16,419,243 · medium
  17,013,207 · high 42,556,542 · out-of-domain 0 — equals the confidence
  tally mapped through the palette, and the probe now fails loudly if it
  ever does not. Deterministic blocks reproduced byte-for-byte across both
  runs, including the three zero-point containers' skip rows.
- **The artifact shows the thesis.** The viewpoint is the median eligible
  frame (783, t 20.539157) looking at the sweep it half-built, near/far
  0.035/43.346 m from the measured span: high-confidence surfaces in blue,
  amber banding at edges and transitions, the far field solid red — the
  sensor's own doubt, visible. Low, medium and high separable at a glance
  was the pass criterion, and the red is not decoration: it is where depth
  ran past 20 m and the sensor said so.
- **Colds are real but small beside the story.** First iterations: 22.3 and
  11.2–12.5 ms for the re-shades, 51–114 ms for the renders — pipeline and
  residency warm-up, printed apart so the warm numbers never absorb them.
  Each iteration is one committed-and-awaited command buffer: a latency
  floor, not a pipelined throughput.
- **The CPU baseline reproduced warm.** 204.3 and 208.3 M points/s against
  commit 2's 200.0 warm — commit 2's cold 57.8 was the file cache, as
  recorded there.

## 2026-08-11 · v0.4 commit 1 — the knobs get their defaults

Four device captures, one walk shape (indoor; 44.9 s for cell A, ~31 s for
B–D), against the three knobs deferred since the commits that introduced
them. Cells: A stride 1 / JPEG 0.7; B stride 2 / JPEG 0.7; C stride 2 / HEIC
0.7; D stride 2 / JPEG 0.5 — each analyzed by a second operator from the
exported `.skewline` container, not the panel alone. Criterion, fixed before
the runs: drops at or below 1% of callbacks, and boundary-only drops — any
chronic interior pattern disqualifies. The second bullet records how that
second half moved.

- **Stride defaults to 2.** Cell A: 918/2688 = 34.15% dropped, chronic
  interior alternation ({1:1013, 2:686, 3:47, ≥4:23} in 16.67 ms units) —
  fails both halves of the criterion. Cell B: 7/1879 = 0.37%, one isolated
  266.8 ms stall at t=8.537 s co-timed with a 514 ms encode spike, 248 clean
  frames before it and 684 after — passes rate, and passes pattern under the
  amendment below. `RenderProbe --png` on both exported containers: A
  unprojects 86,450,264 points over 1,770 frames, B 45,514,752 over 933 —
  half the frames — and the two offscreen renders are equally dense and
  coherent from a comparable viewpoint, so the sparser cloud still meets the
  render-adequacy bar the brief named.
- **The pattern criterion gained a third permitted shape, and cell D closed
  it.** Cell B's isolated stall was neither the chronic `{1,2}`-alternation
  the original criterion targeted nor a literal boundary position, so an
  amendment — recorded after cell B's data revealed the shape, before
  scoring the cell — admitted a third shape: an isolated, non-repeating
  interior stall bracketed by long clean
  runs, provisional on the remaining stride-2 cells not repeating it. Cell
  C's failure doesn't test this — its drops are fully explained by its own
  encoder, not stride. Cell D, sharing B's stride and JPEG encoder, closed
  the question: 0/1842 dropped, histogram {1:920}, no interior events at
  all. The stall was a one-off, not a property of stride 2.
- **Encoding stays JPEG; HEIC failed chronically.** Cell C: 414/1809 =
  22.89% dropped (45.7% of keep-classified frames), chronic from t=0.5 s to
  the end. Mechanism, not a guess: HEIC's own encode mean, 53.31 ms, exceeds
  the 33.33 ms keep budget stride 2 buys outright — the mean alone caps
  retention near 62.5%, and encode spikes (max 271.9 ms, lag max 834.7 ms)
  push the measured loss further. The bytes HEIC would have bought (103
  KB/frame against JPEG's 201 KB, −48.8%) at 3.59× the encode time are moot:
  an encoding that cannot hold the budget is not a candidate.
- **Quality defaults to 0.5, on bytes and an eyeball check — not a render
  check.** Cells B (0.7) and D (0.5) both pass the drop criterion
  identically (encode mean 14.84 ms vs 15.13 ms) — quality does not move the
  frame budget at this stride, so the decision is bytes only: 135 KiB/frame
  against 201 KiB, −32.8%. `Sources/Render` never imports a camera pixel
  type — grepped, confirmed — so neither `RenderProbe` nor a rendered PNG
  can judge this knob; nothing in the pipeline reads JPEG bytes today. The
  visual basis is a 100% inspection of frames extracted from both
  containers, including 0.5's own byte-max frame (291 KiB): no blocking,
  mosquito noise or banding at 100%. Caveat on record: this was
  not a same-scene comparison across qualities, and the run's hardest case
  for compression artifacts — the dim/blinds-class lighting commit 5
  exercised — was only ever captured at 0.7. The default is provisional by
  consumer absence, not by a settled visual judgment, and is worth
  re-running the day something downstream decodes RGB.
- **Depth compression stays LZFSE — decided without a fifth cell.** The
  0.18–0.20 ratio already reproduced across three separate captures with
  different walks (commits 4, 5, the intrinsics probe) — cross-condition
  reproduction judged stronger evidence than one more same-walk measurement
  could add. The raw-vs-lzfse encode-time delta was never isolated (every
  measurement bundles packing, tallying and compression as one number), but
  it cannot flip the decision either: the measured depth-encode bundle,
  4.96–5.48 ms across the four cells, sits well inside stride 2's 33.33 ms
  budget regardless of which side of that delta wins.

Session UUIDs, recorded against their cells the moment each capture ended:
A `17516358…`, B `7BA08EE7…`, C `7FEF8065…`, D `1E2A4BED…`, exported to
`~/dev/Skewline-captures/`. Full panels live with the second operator's
per-cell analysis, not here.

## 2026-08-11 · the README image, and a third clean stride-2 walk

The capture for `docs/media/cloud-confidence.png` — published under the
operator's recorded exception to the capture-privacy rule — doubled as a
third consecutive flawless run on the committed stride-2 defaults: 0/1845
dropped, histogram `{1:922}`, no interior event of any size. 44,973,892
points over 915 depth frames, 21.4% less than fully trusted (low 3,247,490 /
medium 6,377,862 / high 35,348,540) — the render's own numbers, reproduced
independently from the container by both operators. fx swung 12.88%
(1273.12–1437.16), the widest range yet — another replication of the
per-frame intrinsics decision, not a new one.

## 2026-08-11 · v0.4 commit 2 — the movie path, behind a knob

**Built and gated; every number awaits the walks.** `VideoStoragePolicy`
routes kept frames to `AVAssetWriter` — HEVC, reordering off, movie and
input pinned to one nanosecond timescale — as `video.mov` beside the
unchanged per-frame depth files, every sample stamped by the same pure
function `StorageProbe` seeks and verifies with, frame-exact by equality
and never nearest-neighbour, while per-frame files stay the default until
the criteria registered before any run (the standing drop criterion; byte
cut ≥ 20%; warm sequential ≤ 2× files; cold seek ≤ 100 ms) are scored on
device. Movie append time, waits, bytes, seek times and crash-tail loss:
not measured yet.

## 2026-08-11 · v0.4 commit 3 — the storage default the walks measured

**Movie storage becomes the default, measured.** Five cells — two movie
walks, one dual-write walk scoring both paths on identical frames, two desk
kills — were scored against the criteria registered before any run, and the
rule fixed in advance resolves without discretion: both gates hold, no
replay ceiling is breached, so bytes decide and the harness defaults to
`.movieTrack(fragmentInterval: 1)`, per-frame files staying behind the knob.
Every number below is the second operator's re-derivation from the exported
containers, not the panel's.

- **Drain, the gate.** M1 0/1756 dropped; M2 9/1750 = 0.51%; D1 10/1766 =
  0.57% (dual double-writes both paths — recorded, not gating). The movie
  path's one systematic cost: a start-anchored non-delivery window at
  first-append encoder spin-up (append max 1499/1814/1601 ms), measured
  1.47/2.10/1.83 s, remainder clean all three times (870/852/871
  consecutive clean gaps) — admitted under a treatment amended twice,
  each time registered before the cell it scored, never after. Window size
  varies; scene light is a candidate variable (n=2, not concluded). Encoder
  prewarm — the writer started before capture — is the engineering path
  that likely deletes the window: future work, recorded not assumed, and it
  does not move this decision.
- **Bytes.** The movie is scene-invariant at ~36.4 KiB/frame across all
  three movie walks; JPEG 0.5 is not (135 KiB/frame bright, 68.3 dark). The
  cut brackets −46.7% (identical frames, dark walk) to −72.9/−73.0% (vs the
  inherited bright baseline) — the ≥20% bar cleared everywhere, and the
  narrowed dark-scene gap is JPEG shrinking, not the movie growing.
- **Replay.** Presentation times exact by equality on 878/866/873 samples,
  nanosecond timescale round-tripped; decoded pixels byte-reproduce across
  two decodes on all three movie containers (analysis Mac; cross-device
  decode stability untested, claimed neither way). Warm sequential
  2.07/2.36/2.20 ms/frame against the file path's 12.54/13.27 — six times
  faster, 0.165–0.19× the 2× ceiling. Cold random 20.87–23.61 ms mean
  against files 14.62 — files 1.4× faster cold, both far under the 100 ms
  ceiling: exactly the split the registered rule resolved in advance, so
  bytes ruled.
- **Failure.** Fragmented at 1 s, a kill at ~15.5 s recovered 423 of 445
  keeps — complete through the last closed fragment boundary, a 0.73 s
  tail lost — with depth/confidence files surviving to the final ingested
  frame. Unfragmented, the same kill left 16,131,338 bytes on disk and
  nothing recoverable: no moov, zero tracks. `fragmentInterval` 1 s is the
  measured default, and every passing drain number above already includes
  the fragment cost. Either way a kill leaves no `session.json` — neither
  layout yields a *session*; this axis scored payload survivability.

Session UUIDs, recorded against their cells the moment each capture ended:
M1 `931A8965…`, M2 `1A68AF96…`, D1 `85E5E2F1…`, K1 `AC73C3A0…`,
K2 `B8B03C5C…`, exported to `~/dev/Skewline-captures/`. Full per-cell
analysis lives with the second operator, not here.

## 2026-08-11 · v0.4 commit 4 — cross-frame reprojection, behind a probe

**Built and gated; every number awaits the replays.** The observable that
needs no ground truth: the same surface seen twice. A depth pixel of frame
i unprojects through pose i and that frame's own intrinsics, projects into
frame i+k through pose i+k and *its* intrinsics, and predicted depth is
compared against the depth the sensor reported there — the disagreement,
binned by the source pixel's confidence class, is the sensor's error
observed. `Unprojector.imagePoint` lands the pixel-space inverse the render
commit had only written in prose; `Calibration` in `Render` carries the
analysis so tests can reach it; `CalibrationProbe` (Core, Replay, Render —
never Capture) formats and times. Criteria registered before any run, all
as defaults in `Calibration.Constants`: depth bands [0.5,1)/[1,2)/[2,3)/
[3,5) m by source depth; separations k = 1, 5, 15, 30 with pair Δt within
±25% of k × 0.0333 s; upper median and MAD of |Δ| plus the signed median;
ordering pass at k = 1 per band with ≥ 10,000 samples in every class,
strict low > medium > high, adjacent classes ≥ 10% apart; drift slope in
mm/s recorded **without** a verdict — declared now, no principled threshold
exists yet. Ten filters in registered order, each removal counted per class
and band, never pooled; three sensitivity variants accumulated in the same
pass lift the edge mask, the class match and the forward-backward gate one
at a time, because the fw-bw radius truncates |Δ| near d²/(fx·b) — a bound
the probe prints beside each band — and an ordering that holds only with a
filter on is a finding, not a pass. The matched bucket measures class-c-
against-class-c *joint* disagreement, two same-class readings, not one
reading against truth. Known floors, recorded not resolved: the half-pixel
grid ambiguity is common-mode and largely cancels; nearest-neighbour
rounding converts to depth error through surface slope and does not.
Calibration table, drift medians, slopes, filter fractions: not measured
yet. The command that measures:
`swift run -c release CalibrationProbe <capture.skewline>`.

## 2026-08-11 · v0.4 commit 5 — the calibration the replays measured

**The confidence classes are real, measured in meters.** Four containers —
the three movie walks and the README capture — replayed through the
registered analysis; every number below re-derives from
`swift run -c release CalibrationProbe <container>`, whose deterministic
block byte-reproduced across two runs before any number was transcribed,
and the second operator's re-derivation precedes the push, the standing
rhythm.

- **Ordering, the thesis gate: 16 of 16.** At k=1 every band of every
  container scores *ordered with margin* — and stays 16/16 with the edge
  mask lifted, 16/16 with the class match lifted. The ordering is not the
  filters' artifact.
- **Per-class scale, [1,2) band at k=1, median |Δ| in meters:** low
  0.0437 / 0.0444 / 0.0614 / 0.0646, medium 0.0155 / 0.0181 / 0.0203 /
  0.0205, high 0.0036 / 0.0043 / 0.0041 / 0.0042 (85E5E2F1 / 2110CDA9 /
  931A8965 / 1A68AF96; the same rank order in every walk). Across bands
  the high class runs 3.1–3.5 mm at [0.5,1) to 7.8–10.8 mm at [3,5); the
  low class 18.9–31.0 mm to 159.7–197.2 mm — an error bar per color,
  7–20× between the classes the palette separates. High-class signed
  medians stay within ±1.7 mm at k=1: no systematic chain bias above the
  rounding floor.
- **Drift, recorded without a verdict as registered.** High-class pooled
  slope +15.6 / +16.3 / +16.7 / +18.0 mm per second of separation
  (fwbw-off +18.3 / +22.0 / +20.6 / +28.7), four walks inside a
  2.4 mm/s spread; medium +8.2 to +27.2. The per-band medians corroborate:
  [1,2) high 4.1 → 6.6 → 11.4 mm across k = 1/5/15 on 931A8965. The map
  is not flat over time; its best class degrades at roughly 16 mm per
  second of separation under replay.
- **The truncation self-flag fired; the low-class drift is refused.** The
  printed bound d²/(fx·b) falls below the low-class medians from k = 5 on
  (0.031 m in [1,2) against 0.035–0.051 m measured), and the gated low
  slopes go negative on three of four walks (−25.7 / −51.8 / −53.5 mm/s) —
  survivorship, not physics. The fwbw-off low slopes (+123 to +280 mm/s)
  are occlusion-inflated upper bounds. Between the two, low-class drift is
  recorded as not measurable by this gate. One calibration caveat rides
  along: [0.5,1) low at k=1 sits at 0.71× its bound on 2110CDA9, with the
  pooled fwbw-off median 17% above the gated one.
- **Filters, counted never silent.** At k=1 on 2110CDA9 the fw-bw gate
  removes 21.5% of low-class [0.5,1) candidates (36,035 of 167,224)
  against 0.008% of high — the rejection rate itself orders by class, an
  independent witness. Δt exclusions: 0–5 pairs per walk and separation;
  M2's 0.100 s gap and the start-anchored windows are handled by count,
  never special-cased.
- **Cost.** 54.8–61.5 s per container, release build, single-threaded
  (timing block, not deterministic).

Containers: M1 `931A8965…`, M2 `1A68AF96…`, D1 `85E5E2F1…`, README
`2110CDA9…`, all in `~/dev/Skewline-captures/`. Full per-band tables and
per-filter class×band counts live in the probe output, one command from
any of them.

## 2026-08-12 · v0.5 commit 1 — the seam, and the reader behind it

**Built and gated; every number awaits a real file.** The rung's charter
calls the interop seam a design question worth answering in public, so it
was answered the way the storage default was: candidates built and compared
before any repository code existed, both ways, on both build jobs.

- **The seam is a C header, not direct C++ interop — measured, not
  assumed.** Two throwaway packages, each a C++ parser target, a Swift
  module in front of it, and a flag-less client behind that, built for
  macOS and `generic/platform=iOS` on Swift 6.3.3 / Xcode 26.6. The direct
  candidate (`.interoperabilityMode(.Cxx)` on the Swift module) builds and
  its tests pass — until the client: a target importing only the Swift
  module fails with `error: 'string' file not found` while rebuilding the
  C++ target's clang module, because every importer rebuilds that module
  in its own language mode. Access-level imports were the candidate tool
  for containing this, and on this toolchain they do not: `internal
  import` hides the API, not the language mode, and the client compiles
  only when it too enables C++ interop. So the direct seam's real price is
  every importer of `Interop`, present and future — `UnitTests`, the
  probes, whatever consumes imported clouds in v0.6 — carrying the mode
  forever. That is the Replay argument again: anything a module imports
  becomes a thing every test drags along. The chosen seam is a pure C
  header (`Sources/PLY/include/ply.h`) over a C++ implementation, and no
  target in `Package.swift` carries `swiftSettings` — the absence is the
  decision.
- **What crosses: contiguous columns, one copy, C++ owns parse-time
  memory.** The C API is an opaque handle whose accessors return counts, C
  strings and pointers into buffers the parser owns; the Swift initializer
  copies each column into a Swift array and frees the handle before
  returning, so nothing with a C++ lifetime survives into the public API.
  Columns cross as `double`, which is lossless for the whole format:
  PLY's integer types are 32 bits or narrower — inside double's 53-bit
  integer range — and its floating types are IEEE 754 already. Rejected:
  zero-copy views (couples ARC to RAII and pushes unsafe types or a
  lifetime-carrying wrapper into the public API) and per-point accessor
  calls (one seam crossing per property per point — millions per cloud).
- **Where imported points land: in Interop's own types, and the ROADMAP
  attach line was wrong.** `Core` has no point type — its records are
  pose, inertial, frame, depth, exposure, intrinsics — and `Render`'s
  `ConfidencePoint` carries an ARKit confidence class, a semantic an
  arbitrary PLY file does not have. So "fills Core from a point-cloud
  file", written before v0.3 put the point type in `Render`, could not be
  done literally without changing `Core`'s shape, which the standing rule
  forbids. Rather than obey the line or bend the rule, this commit
  corrects the line: `Interop` owns `PLYFile`/`Element`/`Property`,
  attaches to the module graph nowhere, and conversion into pipeline
  types is deferred to the first consumer that needs one.
- **The subset, stated not implied.** Parsed fully: the header grammar
  (both spellings of all eight scalar types, `comment` and `obj_info`
  preserved verbatim), arbitrary elements and property lists, and all
  three encodings — ASCII line-per-instance with exact token counts,
  both binary endiannesses byte-walked with bounds checks. Preserved but
  deferred: list property *values* are decoded — a data-dependent layout
  cannot be walked otherwise — and only their per-instance counts are
  retained. Rejected loudly, each with its fixture: bad magic, unknown
  encoding or version, missing format line, unknown type token,
  non-integral list count type, property before any element, duplicate
  property name, unknown header keyword, missing `end_header`, truncated
  data in either encoding, malformed ASCII lines, a negative binary list
  count — signed count types are legal at the header, and cast unchecked
  a negative count would misalign the byte walk silently. A hostile
  declared count cannot crash the host: the storage reserve is clamped,
  growth is bounded by the bytes the file actually holds, no C++
  exception crosses the C boundary, and an absurd count resolves to the
  truncation refusal. Ignored by declaration: bytes after the last
  declared instance. Fixtures are
  synthetic literals written to a temp directory at test time; no `.ply`
  enters the repository and nothing derives from a capture.
- **Not measured yet.** Parse throughput, bytes per second, memory —
  correctness has fixtures, throughput needs a real file, and no real
  file has been read yet. The subject exists: `InteropProbe --dump
  <capture.skewline> <out.ply>` writes a probe-local binary PLY from a
  replayed container (the writer lives in the probe, never the library;
  the output stays on the Mac). The command that will measure:
  `swift run -c release InteropProbe <file.ply>`.

## 2026-08-12 · v0.5 commit 2 — the reader the containers measured

**Parse throughput and memory are measured, against real files.** The four
containers v0.4 commit 5 already calibrated against were dumped through
`InteropProbe --dump` and each dumped PLY read back twice: `swift build -c
release` once, unmeasured, then `/usr/bin/time -l .build/release/InteropProbe
<file.ply>` per read — the built binary invoked directly, never through
`swift run`, so the reported memory is the probe's own process and not the
SwiftPM driver wrapping it.

- **The four containers, both runs.** M1 `931A8965…` (556,548,325 bytes,
  42,811,392 vertices) reads at 4465.0 ms · 124.6 MB/s · 9.6 M points/s then
  3101.9 ms · 179.4 MB/s · 13.8 M points/s, peak RSS 5,933,318,144 B
  (5.53 GiB) then 5,125,193,728 B (4.77 GiB). M2 `1A68AF96…` (547,602,661
  bytes, 42,123,264 vertices): 3145.4 ms · 174.1 MB/s · 13.4 M points/s then
  2945.1 ms · 185.9 MB/s · 14.3 M points/s, RSS 6,245,187,584 B (5.82 GiB)
  then 6,563,446,784 B (6.11 GiB). D1 `85E5E2F1…` (552,075,493 bytes,
  42,467,328 vertices): 2940.8 ms · 187.7 MB/s · 14.4 M points/s then
  2908.2 ms · 189.8 MB/s · 14.6 M points/s, RSS 6,134,415,360 B (5.71 GiB)
  then 6,686,932,992 B (6.23 GiB). README `2110CDA9…` (584,660,825 bytes,
  44,973,892 vertices): 3139.3 ms · 186.2 MB/s · 14.3 M points/s then
  3254.7 ms · 179.6 MB/s · 13.8 M points/s, RSS 6,011,355,136 B (5.60 GiB)
  then 5,972,705,280 B (5.56 GiB). Every deterministic block — encoding,
  byte count, element and property layout, vertex count — byte-reproduced
  across its two runs; timing and memory did not and are reported as the
  pair each run printed, never averaged into one number.
- **What the timing covers.** `report(on:)`'s `ContinuousClock` wraps only
  `PLYFile(contentsOf:)` — the parse and the column copies from the C++
  side into Swift arrays — not `positions()`, which runs afterward and
  builds the vertex count printed just below it. `MB/s` and `M points/s`
  are the parse-and-copy bill, not a file-to-positions number.
- **Memory ran 9.2–12.1× the file it read across these eight reads, and
  that scale is the architecture, not a leak.** Every scalar column,
  including `confidence` (a `uchar` in the file), is materialized as
  `double` inside the C++ parser, then copied a second time into Swift
  arrays before `ply_free` runs — two full in-memory materializations of a
  widened representation, on top of the whole file first read into one
  `std::string` buffer. A few hundred megabytes of file became 5.1–6.7 GB
  of peak resident memory across all four containers in these runs.
  Whether that bill motivates a streaming reader or narrower in-memory
  types is a later commit's decision, not this one's.
- **The cross-anchor holds.** README `2110CDA9…`'s dump reports exactly
  44,973,892 points over 915 of 923 depth frames — the accumulated-cloud
  count the "README image" entry already recorded for this capture,
  reproduced independently by the dump and confirmed again on read.
- **Dump cost, probe-local, context only.** `InteropProbe --dump` itself:
  M1 871/878 frames unprojected → 42,811,392 points, 556,548,325 bytes; M2
  857/866 → 42,123,264 points, 547,602,661 bytes; D1 864/873 → 42,467,328
  points, 552,075,493 bytes; README 915/923 → 44,973,892 points,
  584,660,825 bytes. The writer lives in the probe, never the library; the
  reader above is the shipped artifact under measurement, this is only
  what produced its input.

Containers: M1 `931A8965…`, M2 `1A68AF96…`, D1 `85E5E2F1…`, README
`2110CDA9…`, all in `~/dev/Skewline-captures/`. The dumped PLYs live beside
them, never staged, never committed.

## 2026-08-12 · v0.5 commit 3 — the values the counts were standing in for

**List property values are retained, closing commit 1's deferral — on the
rung's own terms, not v0.6's.** The ROADMAP's test for anything below the
v0.5 line is whether the rung below forces a change or it would merely
look good. v0.6 (fit) consumes vertex positions and confidence, scalar
columns already fully retained; list properties are conventionally face
indices, and an offline fit over point uncertainty has no use for them.
So v0.6 does not force this commit, and it is not offered as if it did.
What forces it instead is v0.5's own charter: "a format with dozens of
properties per point is the wrong job for Swift." A list property's
per-instance layout is the data-dependent part of that job — you cannot
skip one without decoding it first, which is exactly why `parseBinary`
already walked every list value byte-for-byte before this commit. That
walk was the expensive, C++-shaped work the seam exists to absorb; a
reader that pays it and then discards the result gives a caller who wants
face indices nothing, for the one property type the seam is most suited
to handle. Retaining the values completes what v0.5 already promised to
ship.

- **The old wording was half right.** Commit 1 recorded "list property
  *values* are decoded ... but not retained." That was true of the ASCII
  path (`parseASCII` already called `parseDouble` per entry and dropped
  the result) but not of the binary path, which only ever advanced past
  each list entry by `count * valueSize` — it never decoded a single list
  value. This commit makes decoding, and retention, true of both paths.
- **What crosses: a flattened column, same shape as scalar properties.**
  `ply_list_values` returns one contiguous `double` buffer per list
  property, flattened across every instance in file order; the paired
  `ply_list_value_count` is an explicit length so the Swift side never
  sums `ply_list_counts` itself to size a read through a raw pointer. The
  Swift-side shape is flat `[Double]`, not nested `[[Double]]`: a
  face-heavy file can have millions of list instances, and nesting would
  be one heap allocation per instance on top of the widening cost commit
  2 already measured. Flat mirrors exactly how `ply_scalar_column`
  already crosses — one allocation per property — so this does not change
  the *ratio* commit 2 measured, only the absolute bytes retained for
  properties that were previously free.
  `Element.listValues(_:)` slices per instance using the running sum of
  the existing `listEntryCounts(_:)`.
  The existing negative-count guard and truncation bounds check are
  unchanged; the binary path's single skip became a per-entry decode loop
  inside the same, already-validated bounds.
- **Coverage gap closed alongside it.** List properties had ASCII and
  binary-little-endian fixtures but no binary-big-endian one, unlike
  scalar columns. A new test exercises the byte-swap path for list values
  the same way the scalar big-endian test already does.
- **Not re-measured.** Commit 2's four dumped containers carry no list
  properties, so their throughput and memory numbers are unchanged and
  were not re-run. List-heavy throughput is not measured yet: no
  list-heavy real file exists among the calibrated subjects.

## 2026-08-12 · v0.6 commit 1 — the fit's data seam, and the criteria before the data

**Built and gated; every fitted number awaits the export and the fit.**
The rung's charter: the uncertainty model is *fitted*, not measured —
numpy's job, offline, what closes the thesis. This commit ships the seam
the observations will cross, the harness that will fit them, and the
criteria the fit will be judged by — registered now, before any real
observation file exists. Real exports derive from home captures and stay
on the Mac, never committed; nothing in this rung runs on a device.

- **A premise in the brief was stale, and the code's own record overruled
  it.** The brief placed the observations "inside CalibrationProbe's
  analysis" and held that libraries do not change. The v0.4 commit 4 entry
  above records the opposite design, deliberately: the analysis lives in
  `Calibration` (Render) "so tests can reach it", the probe only formats,
  and executables cannot be imported by the test target. A probe-local
  export would therefore re-implement the registered filter chain in
  untestable code — the silent-drift failure mode. So `Calibration.analyze`
  gained an additive, default-nil `observationSink` instead, existing
  callers untouched, and the emission point is itself registered: the sink
  fires exactly where a sample survives all ten filters and enters the
  default buckets — never a sensitivity variant, never anything the report
  does not count. Three tests hold it there: conservation (the sink's
  samples, grouped per class × band × k and summarized, re-derive the
  report's own buckets exactly), observation-only (the report is equal
  with the sink nil and attached), and the occlusion fixture (everything
  reaches the chain, nothing survives, nothing is delivered).
- **Both new Swift test families were shown red before being trusted.**
  Emitting from the fwbw-off site turned the occlusion test red
  (25 delivered against 0 expected) while conservation stayed green — its
  fixture has no forward-backward rejections, so the two populations
  coincide there; the division of labor between the tests is recorded, not
  hidden. Dropping every second observation turned conservation red
  (counts and MAD both caught it). Both restored; 120 tests green.
- **The export, the `--dump` precedent.** `CalibrationProbe
  --dump-observations <out.csv>` (exactly one container per invocation —
  two would interleave sessions under one provenance header) with
  `--observation-decimation N`, registered default 64: one counter per
  (k × class × band), starting at zero, keep when `counter % N == 0` —
  systematic-every-Nth over the analysis's deterministic accumulation
  order, no randomness. The file: a `#` header carrying the schema tag
  `skewline-observations/1`, the session UUID, every registered constant,
  the decimation, and the per-bucket pre-decimation survivor counts a
  decimated file cannot otherwise recover — then bare
  `k,delta_t,class,depth,delta` rows, floats as Swift's shortest
  round-trip `description`. Decimated raw export, not binned aggregates,
  registered with the information loss argued: decimation preserves the
  per-observation distribution so any later statistic is recomputable,
  where binning would freeze today's statistics and make pooled baselines
  inexact; the sampling error of a bucket median at the argued
  post-decimation scale sits under the ordering margins the calibration
  already banked. The writer lives in the probe, untestable by the
  established `InteropProbe --dump` trade; everything statistical is
  library-side and tested.
- **The registered criteria.** Data: the k=1 rows of the registered
  export; three classes fitted and judged independently. Candidates: the
  banded table (incumbent), affine a + b·d, quadratic a + b·d², power
  a·d^p with p on the grid [0.5, 3.0] step 0.05 — the table is what must
  be beaten, affine is first order, d² is the triangulation-noise shape
  and the fw-bw bound's own, the power law lets the data pick the exponent
  and nests both. Objective: pinball loss at τ = 0.5 on raw observations —
  the same objective the metric scores; the power scale is closed-form per
  grid point (weighted median of |Δ|/dᵖ with weights dᵖ), affine and
  quadratic run a fixed 50-iteration IRLS with residual floor 1e-9 m from
  an unweighted least-squares start. The per-band upper median *is* the
  piecewise-constant L1 minimizer, so the baseline is automatically
  coherent and a continuous form can only win through within-band depth
  resolution and generalization. Positivity gate: σ̂(d) ≤ 0 anywhere on a
  0.01 m grid over [0.5, 5.0] disqualifies before selection. Split:
  leave-one-out over the four calibrated containers (M1 931A8965…, M2
  1A68AF96…, D1 85E5E2F1…, README 2110CDA9…), and in each fold BOTH
  candidates — every form and the table it must beat — are built from the
  same three fit containers, never from all four. Metric: mean
  per-observation L1 against σ̂ on the held-out container, per class.
  Adoption: strictly better than the fold's table in all four folds, ties
  to the incumbent, per-fold margins reported so a squeaker is visible;
  among all-fold winners the lowest unweighted mean of per-fold metrics
  (one container, one vote); the winner refits on all four containers, and
  those final coefficients are never themselves holdout-validated — only
  the form is. Any class that clears nothing is REFUSED and keeps the
  table; a mixed artifact is a legitimate outcome, the refused-low-drift
  shape. Two properties recorded so the measured numbers cannot be
  misread: the metric has an irreducible floor (the spread of |Δ| itself,
  largest for the low class) and selection is a paired comparison
  unaffected by it; and observations are heavily correlated across
  neighbouring pixels and frames, so no i.i.d. standard error is claimed —
  the unanimity bar is the guard, and that is why it exists. Pooling
  across containers — inside a fold's baseline and in the final refit — is
  a declared break from the per-container reporting of v0.4/v0.5,
  justified by one device class and containers as exchangeable scene
  samples, registered here before any pooled number exists. Fine bins
  (0.1 m, minimum 100 samples) are diagnostics printed beside the fit,
  never the fit path. The n = 4 external-validity caveat stands and is not
  resolved here.
- **Drift stays recorded-only.** Δt and k ride the schema, but no drift
  term is fitted this rung: v0.4 refused low-class drift on the fw-bw
  truncation self-flag, and a drift model fitted through k ≥ 5 data would
  launder that refusal into a coefficient.
- **The artifact, registered not produced.** `skewline-fit/1`, JSON, small
  and aggregate: per class the verdict and either the adopted form with
  coefficients or the refused class's table, plus every fold's metrics and
  margins; at the top the estimand with fixed wording — "upper median |Δ|
  of same-class cross-frame reprojection at k=1 under the registered
  filter chain, meters, pairwise — not a single-reading sigma" — with
  `units: meters` and `outsideDomain: refuse`, so no later rung invents
  what the number means, how to read it off a device, or what to do beyond
  the domain. Whether a real fitted artifact may ever be committed is not
  decided here; it derives from home captures even as an aggregate, and
  the measured commit argues it with the privacy rule in hand.
- **The Python harness.** `Fit/`: `fit.py` (reader, forms, fitting,
  selection, artifact I/O — every registered value a module constant),
  `test_fit.py` on stdlib `unittest` so numpy stays the only dependency,
  `requirements.txt` pinning numpy==2.5.2 — the version pip resolved at
  first verified install, not a chosen number — and `.python-version`
  pinning 3.13.1, which pyenv reads locally and `actions/setup-python`
  reads in CI: one pin, two readers, where a floating runner interpreter
  against an exactly pinned numpy breaks the day the image outruns the
  wheels. Sixteen tests, all seeded: per-form synthetic recovery; a
  median-not-mean test (asymmetric noise with mean ≈ 3.1× median — a
  silent mean regression cannot pass); decimation invariance at the scale
  the seam argues, on the curve rather than the coefficients, because
  parameters trade off along a fit; adoption of a planted form; refusal on
  band-constant data; positivity disqualification; artifact round-trip
  including the mixed outcome; schema-tag rejection on both file kinds.
- **The Python red, on the highest-stakes invariant.** Inverting the
  beats-the-table comparison in selection turned three tests red at once,
  including refused-on-band-constant — a fabricated *adoption* is exactly
  what the suite must be able to catch, and now demonstrably can.
  Restored; 16 tests green.
- **CI and the gate grew together.** A fourth job runs the harness's tests
  on macos-26 with the runner's Python printed rather than assumed;
  README's counted sentence became "Four CI jobs" in the same commit,
  which Assertion 4 enforces mechanically; the pre-staging gate is five
  commands now, the Python tests fourth and the drift check still last,
  and CLAUDE.md's gate section says so. `.venv` joined the drift script's
  tree-walk skips beside `.build`.
- **Not measured yet.** The registered export's row counts, file sizes
  and runtime; every fold metric, margin and coefficient; every verdict.
  One stride-8 smoke dump of a single container did run, to prove the
  plumbing end-to-end — probe writes, `fit.py` reads, all three classes
  cross — and was deleted; its numbers are not the registered export's
  and none is recorded. The command that will export:
  `swift run -c release CalibrationProbe --separations 1
  --dump-observations <out.csv> <capture.skewline>`. The command that
  will fit: `.venv/bin/python Fit/fit.py <model.json> <m1.csv> <m2.csv>
  <d1.csv> <readme.csv>`.

## 2026-08-12 · v0.6 commit 2 — the fit the observations measured

**The fit split: two classes beat the table, the third didn't.** Both
registered commands ran, twice each, against the same four containers
v0.4 commit 5 and v0.5 commit 2 already measured — M1 `931A8965…`, M2
`1A68AF96…`, D1 `85E5E2F1…`, README `2110CDA9…` — with nothing about the
criteria touched: same candidates, same power grid, same IRLS settings,
same leave-one-out split, same adoption bar. No code defect surfaced, so
this is a docs-plus-artifact commit, no source changes.

- **Low: adopted, quadratic.** `a=0.022173, b=0.011175` for `a + b·d²`.
  Table / quadratic per holdout fold: 931A8965 0.416260 / 0.416254
  (margin +0.000006), 1A68AF96 0.203050 / 0.201341 (+0.001709), 85E5E2F1
  0.127193 / 0.124603 (+0.002590), 2110CDA9 0.141923 / 0.140695
  (+0.001228) — quadratic beats the table in every fold. Affine and power
  also cleared every fold (affine margins +0.000922 / +0.001409 /
  +0.001184 / +0.001372; power +0.000593 / +0.001401 / +0.001850 /
  +0.001389) but quadratic's mean per-fold metric was the lowest among
  all-fold winners, so it won the form comparison.
- **Medium: adopted, quadratic.** `a=0.010529, b=0.002781` for `a +
  b·d²`. Table / quadratic per fold: 931A8965 0.029069 / 0.028988
  (+0.000081), 1A68AF96 0.031396 / 0.031335 (+0.000061), 85E5E2F1
  0.023286 / 0.022835 (+0.000450), 2110CDA9 0.028157 / 0.027846
  (+0.000311). Affine and power also swept every fold (affine +0.000264 /
  +0.000159 / +0.000090 / +0.000258; power +0.000244 / +0.000090 /
  +0.000146 / +0.000245); quadratic's mean metric was again lowest.
- **High: refused.** No form beat the table in all four folds — every
  candidate lost at least one, and by margins an order of magnitude
  smaller than low or medium's: affine lost 85E5E2F1 (table 0.004440 vs
  0.004450, margin -0.000010) despite beating the other three; quadratic
  lost 931A8965 (0.004853 vs 0.004854, -0.000001) and 2110CDA9 (0.004936
  vs 0.004944, -0.000008); power lost 931A8965 (-0.000003) and 85E5E2F1
  (-0.000018). Whichever container is held out flips the sign of a margin
  this small — which is exactly the case the unanimity bar exists to
  refuse rather than average away. High keeps the table: edges `[0.5, 1,
  2, 3, 5]`, medians `[0.0032641888, 0.004096031, 0.0062491894,
  0.008943319]`, refit on all four containers pooled.
- **Determinism, both stages.** Every export ran twice into separate
  files and byte-compared identical: M1, M2, D1, README all `diff`-empty
  across their two runs. `fit.py` ran twice into separate output paths;
  the two `model.json`s are byte-identical (`diff` empty) — the only
  difference between the two stdout transcripts is the echoed output
  path on the final line. Sixteen Python tests green
  (`.venv/bin/python -m unittest discover -s Fit -v`), matching commit
  1's count exactly — no discrepancy to record.
- **Consistency observation (recorded, not gated).** The exported,
  decimated CSV's own `[1,2)`-band, `k=1`, high-class upper median beside
  v0.4's full-population figure for the same band, with the bucket's
  pre-decimation survivor count (`# survivors k=1 class=2 band=1`) and
  the decimated row count actually used: D1 `85E5E2F1` 0.003631 vs 0.0036
  (Δ 0.000031; 9,912,725 survivors, 154,887 decimated rows), README
  `2110CDA9` 0.004327 vs 0.0043 (Δ 0.000027; 13,427,266 survivors,
  209,802 rows), M1 `931A8965` 0.004125 vs 0.0041 (Δ 0.000025;
  12,077,059 survivors, 188,705 rows), M2 `1A68AF96` 0.004233 vs 0.0042
  (Δ 0.000033; 12,122,014 survivors, 189,407 rows). Every difference is
  under 0.00005 — the quantization width of v0.4's own 4-decimal-place
  figures — so each reads as agreement, full stop; none needed the
  bucket's raw survivor count to explain it. The bare
  `1/sqrt(survivors)` heuristic (~0.03%) undershoots the observed
  relative gap (0.6–0.9%) by roughly 20–30×, which is expected once
  v0.4's rounding is the binding constraint rather than sampling noise —
  not a finding, and not investigated further.
- **Export stats, per container (both runs identical).** M1 `931A8965`:
  32,268,881 survivors, 504,208 rows kept, 23,898,130 bytes, analysis
  32.43 s then 32.91 s. M2 `1A68AF96`: 29,991,724 survivors, 468,627 rows
  kept, 22,221,228 bytes, 29.95 s then 29.55 s. D1 `85E5E2F1`: 29,827,060
  survivors, 466,054 rows kept, 22,019,410 bytes, 31.67 s then 30.37 s.
  README `2110CDA9`: 31,200,020 survivors, 487,505 rows kept, 23,055,038
  bytes, 40.76 s then 32.11 s (timing not deterministic, reported as
  printed, never averaged). Spot-checked the header's own arithmetic on
  M1's `k=1 class=2 band=1` bucket: 12,077,059 survivors, 188,705 rows
  kept — matches `⌈survivors/64⌉` exactly.
- **The artifact enters the repository.** `Fit/model.json` is staged
  alongside this entry. The framing that git history is harder to walk
  back than a DEVLOG paragraph is a false asymmetry: this entry is
  itself committed to git history, and it already discloses every
  verdict, every fold's coefficients and metrics, and the refused
  class's band medians in prose. `model.json` is a strict subset of that
  same disclosure, only machine-readable — withholding the JSON while
  committing the prose containing the same numbers would be privacy
  theater, not privacy. The line this repository has actually drawn,
  twice, is aggregates yes, raw-or-reconstructable never: DEVLOG's
  per-band medians (v0.4 commit 5) and the `cloud-confidence.png`
  capture (published under the operator's recorded exception to the
  capture-privacy rule) both cleared it; the PLY bundles, RGB frames, and
  the observation CSVs themselves never do and stay local regardless, no
  exception, as registered. `model.json` sits on the aggregate side:
  per-class verdict, coefficients, four fold metrics — no raw observation
  appears in it. One thing worth saying plainly rather than burying: the
  artifact's `trainedOn` field lists all four session UUIDs, so the n=4
  provenance stays machine-visible to any consumer of the committed
  file, exactly as it's already human-visible above.
- **Not measured yet.** `fit.py`'s own wall-clock runtime — no `time`
  wrapper around either run, though both completed well within the
  session (observationally fast, not timed).

Containers: M1 `931A8965…`, M2 `1A68AF96…`, D1 `85E5E2F1…`, README
`2110CDA9…`, all in `~/dev/Skewline-captures/`. The exported CSVs stay
local beside them, never staged, as registered; `Fit/model.json` is the
one derived file this rung commits, for the reasoning above.

## 2026-08-12 · v0.7 commit 1 — the seam that carries the model, and the wire's privacy line

**Built and gated; the endpoint has no consumer yet and no performance
number.** Every prior privacy call in this repository was about what enters
the tree. A network asks a different question, and this commit answers it
before any endpoint has a caller. No Swift code ships and `Package.swift`
is untouched.

- **The charter contradicted itself, and the privacy answer decided which
  half survives.** The attach block says "v0.7 Service — serves what Fit
  produced, back to the device" (model down); the next-table said "the
  client uploads a bundle and gets a model back" (capture up). Those are
  different data flows. **The model goes down and nothing goes up.** The
  attach line was already accurate and stands verbatim; the next-table
  line is the one corrected, the way v0.5 commit 1 corrected "fills
  Core" — argued here rather than quietly reworded. The deciding argument
  is not privacy. **At n=1 upload is unsupported, not merely unwise.**
  `select_for_class` fits each class by leave-one-out across containers
  and adopts only on a unanimous sweep of the folds; it raises on fewer
  than two containers. One client's bundle has no fold and no holdout, so
  an upload endpoint would have to run criteria that do not exist — which
  is exactly what v0.6 spent a rung refusing to do. Upload therefore moved
  to *Deliberately not built* with a written trigger, the shape this repo
  already uses for on-device inference: it revisits when a registered
  procedure exists that can fit or update a model from one client's data,
  **and** the wire's privacy line is decided for that payload class.
  Registering "aggregates up later" instead was rejected on the ROADMAP's
  own divider — v0.7 is a rung, not a commit list, and a trigger registers
  scope without deciding a later commit's content.
- **What crosses, and what the standing rule now means.** Down: the
  `skewline-fit/1` artifact — per-class verdicts, coefficients or the
  refused class's table, fold metrics, the estimand, `units`,
  `outsideDomain`, `depthDomain`, and `trainedOn`'s four session UUIDs.
  All of it is already committed as `Fit/model.json`, so **the endpoint
  serves what the repository already serves**. Up: nothing. No frame, no
  depth map, no pose, no observation row, no container. The
  aggregates-yes/raw-or-reconstructable-never line now governs the wire as
  well as the tree, with one tightening the tree never needed: a git blob
  is pulled by whoever cloned the repo, but a network request has a
  requester a host could log, so the service accepts no request body at
  all.
- **The load-bearing exclusion is the per-point query, and it is the one a
  reader would not predict.** A "what is σ̂ at depth d" endpoint sends the
  *client's* depths up. The model is public; the client's questions are
  not. So there is no evaluation endpoint and no query surface — the whole
  artifact goes down and the consumer evaluates locally, which is why the
  API is one GET. The manual check made this concrete rather than
  theoretical: the request log line for a rejected query reads `"GET
  /v1/model?class=high&depth=2.0 HTTP/1.1" 404`, with the depth in it. Had
  the query surface existed, that is where the client's scene measurements
  would have landed.
- **Enforced by the router, not promised in prose.** Path matching is
  exact, so a query string is not this endpoint; every method other than
  GET and HEAD answers 405 with `Allow: GET, HEAD`; and no route reads a
  request body anywhere in the module.
- **The honesty item, so "nothing sensitive crosses" is not overclaimed.**
  The *response* is public aggregate. The *requests* are not nothing: any
  real deployment's log carries client address, user agent and timestamps.
  This commit's service writes no log file — the stdlib handler's one line
  per request goes to stderr and that is the whole of it — but the
  retention question belongs to whoever deploys, and is recorded here
  rather than registered away.
- **No authentication, as a finding rather than a shortcut.** Nothing
  served is private; it is already in a public git repository. Auth over
  public aggregates would be theater, and saying so is the point.
- **Where it lives, and why the rung named Service has no `Service/`.**
  `Fit/serve.py` and `Fit/test_serve.py`, beside the fit. The v0.6 lesson
  decided it: the service must read `skewline-fit/1` through
  `fit.read_artifact` rather than re-parse it, or the two drift silently,
  and a same-directory `import fit` is the strongest mechanical guarantee
  of that — no path shim, no packaging layer, each of which is a way for
  the two to come apart. It also keeps `unittest discover -s Fit` the one
  command that finds every Python test, so the gate stays five commands
  and CI stays four jobs. The cost is that a reader greps for `Service/`
  and finds nothing: ROADMAP's attach line names a rung, not a directory,
  and this paragraph is where that reader should land.
- **The import runs one way, and the dependency line has a registered
  move-out condition.** `serve.py` imports `fit`; `fit` learns nothing
  about serving — the same shape as Replay never depending on Capture,
  because anything the fit imports becomes a thing every numerical test
  drags along. Stated precisely: **the service adds no dependency.** It is
  not "stdlib only" — numpy arrives transitively through the reader, which
  is the point. `Fit/requirements.txt` is the *fit harness's* pin file and
  CI's fit job installs it to run numerical tests, so the moment serving
  needs a third-party dependency, those tests start dragging a web
  framework along and `fit.py`'s "numpy is the only dependency" claim goes
  false. Registered now rather than discovered later: a non-stdlib serving
  dependency means its own directory and its own requirements file, in the
  commit that introduces it.
- **Two versions, of two different things.** `skewline-fit/1` is a schema
  tag on the *payload*; `/v1/` versions the *endpoint set and error
  shape*. They cannot be one thing, because an error response carries no
  payload tag at all — a 503 body has no `schema` field to read — so
  something must version the envelope, and one path segment is the
  cheapest thing that can. A consumer reads both, and the 200 body always
  carries its own tag so the payload version is never inferred from the
  path.
- **The endpoint.** Local, bound to `127.0.0.1`, with no flag to bind a
  public interface — that default is a privacy decision, not a
  convenience. A deployed host is an uptime-and-secrets commitment this
  repository has never made; what the choice defers is TLS, real exposure,
  rate limiting, log retention, and who runs it. No secret, token or
  hostname enters the tree. `--port` defaults to 0 and the bound port is
  printed, so no invented port number is committed and the operator's path
  is the tests' path. `GET /v1/model` → 200; no artifact yet → **503**
  `no-model` rather than 404, because the endpoint exists and is correct
  while the service has nothing to serve *yet*, and refusing to start
  would make that state untestable; an unreadable or wrong-tagged artifact
  → **500** `bad-artifact`, refused at read rather than proxied, since a
  foreign file is the operator's problem and must not reach a client; an
  unknown path → 404. The artifact is re-read **per request**, so a fit
  landing while the service runs is served without a restart.
- **HEAD is answered, and that was a decision rather than a leftover.**
  RFC 9110 §9.1 makes GET and HEAD the two methods a general-purpose
  server MUST support and every other method optional, so 405 on
  POST/PUT/PATCH/DELETE/OPTIONS conforms while 405 on HEAD would not. It
  is also right on this rung's own terms: the refusal is about methods
  that carry a body, and HEAD carries none, so refusing it would be
  theater on a method that cannot upload anything. HEAD returns GET's
  status line and headers — including the `Content-Length` GET would send
  — with an empty body. `curl -I` is the first thing a reader tries.
- **What never reading the request body costs, stated rather than
  discovered later from a confused client.** The stance is right and
  stays. The consequence is that the server answers 405 and closes with
  unread bytes still in flight, so a client sending a body larger than the
  socket buffer can see a connection reset instead of the 405. The tests
  keep their bodies small on purpose, so the upload test exercises the
  router rather than the kernel's buffering.
- **The byte-identity claim, pinned to its scope.** A 200 is served as
  `json.dumps(artifact, indent=2, sort_keys=True)` plus a newline — the
  exact shape `write_artifact` produces — so it reproduces **the bytes
  that writer writes**, and the committed `Fit/model.json` is such a file.
  It is not a claim about arbitrary artifacts: one edited by hand but
  still schema-valid is served *normalized*, not byte-for-byte as it sits
  on disk. Someone who hand-edits an artifact and diffs the response is
  meeting a property that was never that broad, not a bug.
- **Fifteen new tests, and the highest-stakes one shown red first.**
  Allowing POST through the router turned the upload test red on all four
  of its methods, and the load-bearing failure is the first: POST returned
  **200 where 405 was expected** — the artifact served on an upload
  method, which is precisely the regression this rung must be able to
  catch. Restored and byte-compared against the pre-inversion file.
  Recorded rather than hidden: the *other* privacy test stayed green
  through that inversion, because it is a source assertion about the
  absence of a body read and cannot witness a routing regression. The two
  tests divide the work; neither covers the other's failure. Every server
  in the suite binds port 0 and reads its port back — a test racing for a
  fixed port is a flake generator.
- **Two defects the manual end-to-end check caught that the tests could
  not.** The port line was block-buffered the moment stdout was a pipe
  rather than a terminal, so an operator redirecting the service got no
  port at all — the one line that matters when the port is ephemeral by
  default; it is flushed now. And the `Server` header went out as
  `Skewline ` with a trailing space, because the base class joins the
  server and interpreter version strings on a space unconditionally and
  the interpreter half was blanked rather than the join overridden. Both
  are the kind of thing a socket test that only reads status codes and
  bodies will never see.
- **The Swift client: registered, not shipped.** It cannot ship here — a
  module or probe needs a `Package.swift` change, which this commit
  excludes — so what lands is the obligation, on Interop's precedent of a
  module owning its own value types. The proposed name is **`Model`**:
  `Service` is already the Python side and the Swift module *consumes* a
  service rather than being one, so by this repo's one-word role-naming
  convention the thing modeled is the fitted model and its reading, not
  the transport. **Both of v0.6's teeth must be unavoidable in the type,
  not one** — the refused class as an enum case, so a caller cannot dot
  through to coefficients that may not exist, *and* `outsideDomain:
  refuse`, so evaluating outside [0.5, 5.0) m returns a refusing result
  rather than a silent extrapolation; a type misusable in either direction
  has lost half the finding. The estimand rides the API: a property named
  `sigma` handing back a `Double` invites exactly the misreading the fixed
  wording exists to prevent, so naming and doc comments carry the pairwise
  meaning, and a consumer wanting a per-reading error bar states its own
  conversion. The schema tag is checked before anything is believed, the
  discipline `fit.py` and the PLY reader already apply. The module owns
  its value types, depends on nothing above, and does not reach for
  `Render.ConfidencePoint` — joining a model to rendered points is the
  consumer's edge, the call v0.5 commit 3 made. And the coupling that
  would otherwise arrive as a red CI: a new `.library` product makes drift
  Assertion 3 demand a bolded module bullet in README **in that same
  commit**, and the prose counts move with it — "Five modules" in both
  README and this ROADMAP's graph header. A probe adds no product and is
  unaffected.
- **The harness rule stands unamended.** README's "it should not grow a
  second job" survives intact: the module is what reaches the device — the
  iOS CI job type-checks it exactly as it does `Render` — and a UI is not
  what makes something reach a device. A Mac-side probe is the established
  way to exercise a library against real input, with four precedents. No
  button in `SkewlineHarness`.
- **The gate did not grow**, which is the placement decision paying off:
  120 Swift tests green, 31 Python (16 fit, unchanged, and 15 serve), both
  iOS builds succeeded, drift green with all four assertions quiet —
  Assertion 3 because no `.library` was added, Assertion 4 because "Four
  CI jobs" still matches four jobs in `ci.yml`.
- **Measured, because the run produced it:** the served payload is 8,210
  bytes, and `curl` reports the same `Content-Length` on HEAD as GET's
  body length. `GET /v1/model | diff - Fit/model.json` came back empty.
- **Not measured yet.** Request latency, throughput, behavior under
  concurrent requests, the per-request file-read cost, and startup time.
  The service has no consumer, so there is nothing yet whose experience
  those numbers would describe. The command an operator runs:
  `.venv/bin/python Fit/serve.py Fit/model.json`, which prints the bound
  port.

## 2026-08-12 · v0.7 commit 2 — the Swift client the service registered

**Built and gated.** Commit 1 registered an obligation and shipped none of
its code; this is that code. `Model` is the sixth `.library`, and the name
commit 1 proposed stands unchanged, so nothing is owed here for it.

- **The module fetches *and* decodes, with the socket in exactly one
  function.** The trade, named rather than assumed: a library that imports
  `URLSession` is not the Replay-must-not-import-Capture case — `URLSession`
  is Foundation, which every module here already imports, so no dependency
  is added and no build grows. What a network drags into a test suite is a
  *call*, not an import, and the fix already exists on the other side of
  this seam: `serve.py`'s router is one function with no socket in it and
  its tests drive that function rather than a port. Mirrored exactly.
  `FittedModel(decoding:)` turns bytes into a model or a refusal;
  `ModelClient.outcome(status:body:)` turns an HTTP status and a body into
  the same; `ModelClient.fetch(from:using:)` is the one function that opens
  a connection, and **no test in the suite calls it**. So the tests are
  network-free by construction rather than by convention, and the repository
  still has one fetch instead of one per consumer — which is the
  second-implementation problem v0.6 and v0.7 both refused.
- **Refused is not unavailable, and the type cannot conflate them.**
  `Estimate` has four cases: `.fromAdoptedForm` and `.fromBandedTable` both
  carry a number, so a class whose fit was refused still answers — which is
  precisely what keeping the banded table bought, and a `case .refused` that
  returned nil would have thrown it away. The two silences are separate
  cases: `.refusedOutsideDepthDomain`, where nothing answers, and
  `.refusedBandWithoutSamples`, where the depth is inside the domain but its
  band had no samples. A caller that only wants the number reads
  `medianPairwiseDisagreementMeters`, which is `nil` for both silences; a
  caller that must tell them apart switches. The other tooth is the verdict
  enum: there is no path from a refused class to coefficients that do not
  exist.
- **The half-open domain resolves an ambiguity the schema does not settle,
  and that is a contract decision rather than a code choice.** The artifact
  carries `depthDomain: [0.5, 5.0]` — two numbers and no inclusivity marker
  — so "does 5.0 m answer?" has no answer in `skewline-fit/1`. This client
  resolves it **half-open**, on the banded table's own band arithmetic
  (`d >= low && d < high`), which makes the table refuse at exactly 5.0; the
  adopted forms are then held to the same boundary, so both verdicts share
  one domain instead of the adopted classes answering one depth further than
  the refused one. Recorded because v0.8's dashboard is the next consumer of
  the same field and could resolve it inclusively, and the two clients would
  then disagree about exactly one depth. Recorded with it so the record is
  complete: `fit.py`'s positivity gate *does* evaluate at 5.0
  (`POSITIVITY_GRID` spans `[0.5, 5.0]` inclusive), so the fit's validity
  domain is closed where this consumer's answering domain is half-open. The
  two are drawn to the same boundary here by choice, not because the schema
  forces it.
- **Three shapes the committed artifact does not contain, each decoded
  deliberately and each exercised by a synthetic fixture.** Coefficients are
  form-dependent — both adopted classes are quadratic with `{a, b}` while
  the power form emits `{a, p}` — so they ride the enum case rather than
  sitting in a dictionary a caller has to know how to read, and no
  unevaluatable form is nameable. A fold's per-form entry is
  `{metric, margin}` **or** `{"disqualified": true}`, so `FormOutcome` has
  two cases and an entry that is neither is refused rather than defaulted. A
  banded table's medians may be null, so the column is `[Double?]` and
  evaluating into such a band is the third silence above rather than a zero
  nobody measured. Zero committed instances exercise any of the three; that
  is what the fixtures are for.
- **Where the folds attach, decided rather than defaulted.** They hang off
  `ClassModel` beside the verdict, with the verdict as an enum *inside* the
  struct. Putting them in the enum — `.adopted(Form, [Fold])` — would tax
  every call site that only wants to evaluate with a binding it does not
  want, and a separate map on `FittedModel` would split what the JSON keeps
  together. The artifact test reaches them, because decoding a shape nothing
  reads is how a decoder rots, and it reaches them through a check that is
  still self-derived: leave-one-out gives one fold per container, so
  `folds.count == trainedOn.count` and every holdout is a session the fit
  was trained on; and `select_for_class`'s adoption bar is re-derived from
  the decoded numbers — an adopted class's winning form beats its fold's own
  table in **every** fold, and a refused class has no candidate that swept.
- **Strict about classes, loose about fold keys — an asymmetry with a
  reason.** An adopted `form` string this type cannot name is refused,
  because a form that cannot be evaluated cannot be adopted. A fold's form
  name stays a `String` key, because a fold entry is a diagnostic, and
  refusing a whole artifact — and with it the model a client needs — because
  a later fit reported a fourth candidate would be the wrong trade. The
  class set is strict in both directions: exactly the three `CLASS_NAMES`,
  no more and no fewer, since a fourth class is a schema-tag question.
- **Two fields are verified because their meaning is hard-coded; the third
  is carried and not gated.** `units` must be `meters` and `outsideDomain`
  must be `refuse` — the evaluator means both, so it checks both rather than
  assuming them. `estimand` is carried verbatim and never compared: gating
  on prose would go red on a rewording that changed nothing, while a changed
  *meaning* is what the schema tag is for. The tag itself is read before any
  other field, and a test proves the *order* by handing over an artifact
  with three things wrong at once and requiring `wrongSchema` to be the one
  reported.
- **Two smaller refusals worth naming.** A coefficient object that is not
  exactly the form's — `quadratic` with an `a`, a `b` *and* a `p` — is
  refused, because quietly ignoring a coefficient the artifact carries is
  the silent coercion this reader exists to avoid. And a refused class's
  table must span the depth domain exactly, or the artifact is refused:
  otherwise a depth inside the domain but outside every band would produce a
  fourth, unnamed kind of silence, and the point of this type is that there
  are exactly the ones it names.
- **The tests reach the committed artifact, not a copy of it.**
  `ModelArtifactTests` walks up from its own `#filePath` to the repository
  root and decodes `Fit/model.json` — the file the service serves. Copying
  it into `Tests/` would have created two files to drift. A missing file
  **fails** rather than skips, on the drift script's own lesson that a check
  which silently skips when its anchor disappears is decoration. Nothing in
  that file transcribes a fitted number: every assertion is either a
  registered constant or re-derived from the decoded artifact, so a refit
  that changes the coefficients leaves it green while a decoder that starts
  inventing numbers does not.
- **Both teeth shown red first.** Making a refused class return
  `.refusedBandWithoutSamples` unconditionally — the exact regression that
  would throw away the model v0.6 fought to keep — turned **seven** tests
  red across all three files, including the committed-artifact one. Moving
  the schema check to *after* the units check turned two red, which is the
  ordering claim being a claim rather than a comment. Both inversions were
  restored and the files byte-compared against their pre-inversion copies.
- **`ModelProbe`, the fifth probe, and no button in the harness.** An
  argument with an `http` scheme is fetched; anything else is a path, and
  both reach the same decoder. `swift run -c release ModelProbe
  http://127.0.0.1:<port>/v1/model` and `swift run -c release ModelProbe
  Fit/model.json` printed **identical** deterministic blocks — verified by
  `diff` over everything between the block markers, empty — with only the
  transport line and the timing differing. Form names are sorted before
  printing, because a dictionary has no order and a block that claims to be
  deterministic cannot inherit one. Fold lines drop the padded label column:
  a session UUID is longer than it, and the first run truncated four
  holdouts into their metrics.
- **What the probe deliberately does not print.** No payload byte count over
  the wire. The client hands back a model rather than a body, and adding a
  second request to count bytes would be a request for a number nothing
  needs; commit 1 already measured that payload with `curl`.
- **Every refusal path driven by hand, against real services.** 404 on
  `/v1/model?class=high&depth=2.0` (the query surface that does not exist,
  with the client's depth in the URL exactly as commit 1 warned), 503
  `no-model` against a service pointed at a missing artifact, 500
  `bad-artifact` against one pointed at a foreign file, and `unreachable`
  against a dead port. Each printed the refusal by name and exited 1; none
  crashed and none produced a number. `POST` still answers 405, checked with
  `curl` because the probe has no way to send one.
- **Sendable, and what is not on an actor.** Every public type is written
  `: Sendable` explicitly — SE-0302 gives a `public struct` no implicit
  conformance and no diagnostic in synchronous code. `fetch` is the only
  `async` API and carries no global actor, so it is nonisolated and a
  `MainActor` caller does not drag the request onto the main thread; its
  result is `Sendable` and crosses back without a hop. `ModelProbe` is
  `@main` on a struct with an async `main()`, because top-level code in a
  `main.swift` would be `MainActor`-isolated and nothing here wants an
  actor. The three registered classes are a struct with three stored
  properties rather than a dictionary, so a lookup the decoder already
  guarantees is not optional at every call site.
- **The gate did not grow.** 163 Swift tests green — 120 before, 43 new, and
  the arithmetic closes exactly. 31 Python, unchanged, because a Swift
  module adds no Python: 16 fit and 15 serve. Both iOS builds succeeded, and
  the package build is what type-checks `Model` and `ModelProbe` for the
  device — the claim that the module reaches the device is the gate's, not
  this paragraph's. Drift green: Assertion 3 now matches six `.library`
  products against six bolded module bullets, and Assertion 4 still reads
  four CI jobs against four jobs in `ci.yml`.
- **The instructions named two prose counts and there were three.** "Five
  modules" in README and in the ROADMAP's graph header both moved to six, as
  registered. The ROADMAP also opens *What has shipped* with "Twenty-six
  steps", which no assertion checks and which the brief did not mention; it
  moved to twenty-seven with the new step. Nothing else was ambiguous, and
  nothing was guessed: the depth ladder the probe prints is a probe-local
  choice and is not registered anywhere.
- **Not measured yet.** Request latency, throughput, behavior under
  concurrent requests, and decode cost. The probe prints a timing line and
  it is labeled non-deterministic; no figure from it is recorded here,
  because one local run against loopback describes no consumer's experience
  and there is still no consumer. Caching is not built either: the client
  fetches when asked, exactly as the service re-reads when asked.

## 2026-08-13 · v0.8 commit 1 — the page the service renders, and the reader that does not exist

**Built and gated.** The rung opens with a second route and no curve. The
question it had to answer first was where the page's reader lives, and the
answer is that there is not one.

- **The premise the rung opened on was wrong, and discarding it discarded
  the whole fork.** The framing was: a browser cannot import `fit.py` or
  `Sources/Model`, so a page that evaluates the model is a **third**
  independent implementation of one schema, and the rung must choose how to
  hold it honest — CI with a node job, a manual check recorded here, or no
  evaluation at all. Every branch assumes the browser reads the artifact. It
  does not have to. **The same service renders the HTML in Python, through
  `fit.read_artifact`, and the browser is handed a finished document.** There
  is no third reader to pin, so the three options were not weighed and
  rejected on their merits; they were built on an assumption that turned out
  to be optional. This is the v0.6 lesson one rung up: `serve.py` refused a
  second parser of the same schema, and the cheapest way to refuse a third is
  to not create one.
- **What that buys, stated so the cost of the alternative is visible.** Every
  refusal requirement became assertable in the existing `discover -s Fit`
  suite. The gate stays five commands and CI stays four jobs, so README's
  "Four CI jobs" never moved and drift Assertion 4 stayed quiet; Assertion 3
  too, because no `.library` was added. No node, no `.gitignore` entry, no
  toolchain pin. The node branch would have cost all five.
- **The page is served at `/`, off the version prefix, and that was argued
  rather than defaulted.** v0.7 registered two versions of two things:
  `skewline-fit/1` tags the payload, `/v1/` tags the endpoint set and the
  error shape, because "an error body has no `schema` field to read." An HTML
  document has no payload version either, so `/v1/view` would promise a
  stability nothing in this repository enforces. Two facts settled it: the
  `/v1/` error shape is already service-wide rather than path-scoped — an
  unknown path has always answered in it, which `test_an_unknown_path_is_404`
  has proved since v0.7 by hitting `/model` — and serving the page outside the
  prefix keeps `/v1/` a set of exactly one endpoint. `/` is also what a person
  types.
- **Which clause of the privacy line acquired an exception, quoted rather
  than paraphrased.** v0.7 commit 1 wrote: "there is no evaluation endpoint
  and no query surface — the whole artifact goes down and the consumer
  evaluates locally, which is why the API is one GET." Read clause by clause
  after this commit: *no evaluation endpoint and no query surface* is still
  true, on both routes; *the API is one GET* is still true of the data api,
  which is exactly why the page sits off `/v1/`. The clause that acquired an
  exception is **the consumer evaluates locally** — the page is the first
  consumer here that does not. It is safe for a reason the sentence does not
  give, and that reason is the one worth carrying forward: **no depth a client
  picked ever travels up.** Every depth on the page is the repository's own,
  fixed in the tree, whether the consumer is Swift evaluating locally or a
  browser being handed a finished document. README's version of the paragraph
  was rewritten around that; this entry is where the reasoning lives.
- **This log is append-only, and that is recorded here once because it was
  questioned.** The instruction for this commit was to correct the v0.7
  passage in place. It was not corrected. Of the 31 commits that have touched
  this file, the only two with deletions are `cd930e6` and `986f6a3`, both
  inside the first eleven; the last twenty are additions without exception.
  Nothing wrote that down, but it is what the history does, and the log's
  stated job — recording mistakes, not only decisions — cannot survive a file
  that gets edited when a sentence becomes inconvenient. Entries here are
  dated and are not edited to stay true. **README is the document kept true,
  and four mechanical assertions police it.**
- **A depth slider is impossible here, and that is a finding rather than
  something left undone.** Making the rendered depths selectable needs either
  script in the browser — the third evaluator, back again — or a query
  parameter, which is literally the per-point query v0.7 refused, with the
  rejected-query log line recorded as its evidence. The page is therefore
  non-interactive on depth **by construction**, not by scope. Exact path
  matching is what makes it mechanical on this route too: `/?depth=2.0`
  answers 404 `no-such-endpoint`, and the detail line names the depth it
  refused to accept.
- **Refusals, as three states that cannot collapse into one another.** A
  refused class reads as refused, says it adopted no continuous form, and
  shows the banded table it kept — which still answers, which is what keeping
  it bought. A band with no samples reads `no samples`, never `0.000000` and
  never blank. Outside the domain nothing answers at all, and that is stated
  above the classes as a property of the domain rather than as an empty cell,
  because it belongs to the domain and not to any one class. There is no path
  on the page from a refused class to coefficients that do not exist, for the
  same reason there is none in the Swift type: there are none to show.
- **Both teeth shown red first.** Rendering a refused class as an empty panel
  — the blank where a refusal belongs, the exact inversion of the thesis this
  repository exists to test — turned **four** tests red across the two files.
  Rendering a null band median as `0.000000` turned **one** red, and its
  failure message shows the band table with a zero sitting in the row nobody
  sampled, which is what the tidy-looking version of that bug looks like.
  Both were restored and the file byte-compared against its pre-inversion
  copy.
- **The domain is read half-open, the second consumer of a field the schema
  does not settle.** `depthDomain` carries two bare numbers and no inclusivity
  marker. v0.7 commit 2 flagged this dashboard as the consumer that could
  resolve it the other way and put the two readers one depth apart; it reads
  it as `Model` does, and says so on the page rather than only here. No
  evaluator is involved — this is a rendered statement of a resolved decision.
- **Three number formats, and the third exists because a sign is a finding.**
  `ModelProbe` has `fixed` (`%.6f`), `bound` (`%.2f`) and `signed` (`%+.6f`),
  and the page matches all three so the two readers print the same numbers at
  the same widths. Margins take the signed one: the high class's fold row
  reads `+0.000003  -0.000003  -0.000001`, and the flip across folds is the
  whole reason that class was refused rather than averaged. `fit.py`'s own
  driver already prints margins `{:+.6f}` too, so the page agrees with both
  sides rather than one. A decimation is a count and prints as the integer the
  export wrote, never at a metric's six decimals.
- **Found and not fixed.** `ModelProbe.fixed`'s docstring says "Six decimals
  for a metric, a margin or a coefficient" — it claims the margin that the
  call site does not send it, which goes through `signed` instead. The
  docstring is stale in shipped code. Not corrected here: `Sources/` is
  outside this commit and a Swift edit would have moved the test count.
- **Two contradictions in the repository, one of them load-bearing for the
  next commit.** `ModelProbe.depths` is commented "The registered ladder", and
  this rung's own instructions call it registered — but the v0.7 commit 2
  entry above says plainly that "the depth ladder the probe prints is a
  probe-local choice and is not registered anywhere." Both cannot hold. It
  matters because the registration below leans on that ladder being the same
  question asked on both sides. Recorded, not resolved: whichever way it goes
  is a one-line change and it belongs to the commit that uses the ladder.
- **What "no script, nothing fetched" actually claims, after the browser
  falsified the tidier version.** The page authors no subresource: no script,
  no stylesheet, no font, no image, so nothing of ours is fetched and nothing
  is evaluated in the browser. It is **not** "one document, one request" —
  a real load is two. Chrome asks for `/favicon.ico` on its own, with no
  markup asking it to, and the request log across the manual check reads
  `"GET / HTTP/1.1" 200` then `"GET /favicon.ico HTTP/1.1" 404`. That refusal
  is the first evidence the exact-match router has been driven by something
  other than `curl`, which is worth more than the sentence it replaced.
- **The `://` assertion is deliberate and it is fragile, said now rather than
  discovered.** "No script and no `://` anywhere in the rendered page" is the
  same shape as v0.7's `"rfile" not in inspect.getsource(serve)` and inherits
  the same weakness: a future comment, or a doctype carrying a namespace URL,
  turns it red for a non-reason. Kept, because what it pins is the rung's
  whole architecture, and a mechanical guard on that is worth an occasional
  false red.
- **The route's mechanics, and the one place the shape had to change.**
  `CONTENT_TYPE` was one module-level constant and two routes now disagree, so
  the content type became a property of the resolved response —
  `resolve` returns `(status, content_type, headers, body)` — rather than a
  branch where the bytes go out. GET and HEAD only on both routes, `Allow:
  GET, HEAD` on the 405, and no route reads a request body: v0.7's source
  assertion passes unmodified. The renderer is stronger than that assertion
  rather than merely compliant with it, because it never receives the request
  object at all — a pure function of the artifact and the shell, which is
  `serve.py`'s own router-with-no-socket split moved one seam out.
- **Errors stay JSON on the page's route, which is a trade rather than an
  oversight.** `/v1/` versions one error shape; an HTML error page would fork
  the envelope for cosmetics and `ERROR_CODES` would stop meaning one thing. A
  browser meeting a 503 sees the body a client would. Both routes read the
  artifact through one function and refuse it identically — a page has no
  better answer to a missing fit than the endpoint does, and writing the
  refusal twice is how the two would come to differ.
- **A missing shell is 500 `no-view`, and the departure from 503 is the
  point.** `no-model` is 503 because the fit legitimately has not run yet — a
  state this service passes through by design, and refusing to start would
  make it untestable. `Fit/view.html` is committed, so its absence is a broken
  checkout: the operator's problem, never the request's, which is the
  `bad-artifact` family. It gets its own code because a missing document and a
  corrupt artifact are different findings. Driven by hand against a directory
  with the shell removed: 500 `no-view`, with `/v1/model` still answering 200
  beside it.
- **The shell is re-read per request, exactly as the artifact is.** Edit the
  page, reload, no restart — and a test drives that by rewriting the file
  between two requests. The cost is a second file read per request, which
  nobody has measured. It is not a caching decision, the same words v0.7 used
  and for the same reason.
- **Registered for commit 2, because the opener is where it is decided.**
  (1) `fit.predict` is a shared evaluator but **not** a shared refuser: its
  own docstring says the parametric forms "are evaluated wherever asked", so
  `predict("quadratic", coefficients, 6.0)` returns a number exactly where
  `ModelProbe` prints a refusal, and its table path returns bare `NaN` for two
  findings the Swift type keeps apart. So a refuser mirroring `Estimate`'s four
  cases has to be **written**, and a second implementation of refusal
  semantics is a heavier thing than a second implementation of arithmetic
  would have been. The obvious home is `fit.py`, beside the declaration it
  enforces — and that home has a cost worth naming now: `POSITIVITY_GRID`
  spans `[0.5, 5.0]` **inclusive**, so the fit's validity domain is closed
  where a consumer's answering domain is half-open, and one module would then
  hold two domains with the same two endpoints, different inclusivity, and two
  different questions. That is the confusion v0.7 predicted between two
  clients, relocated inside one module, where no language boundary makes it
  visible. Commit 2 either places the gate there **with** two distinctly named
  domains, a line at each saying which question it answers, and a test pinning
  5.0 answering differently in the two — or concludes that this is reason
  enough to put it elsewhere, and says where. Both are legitimate; what is
  registered is the constraint, not the location.
  (2) The rendered ladder is `ModelProbe.depths` verbatim, so Python and Swift
  answer identical questions and drift shows up by comparing two outputs that
  already exist — no new mechanism, no new job, no new toolchain.
  (3) Refusals before the curve, the order v0.6 used when it froze criteria
  before data. No curve is drawn until (1) and (2) are in, and the page's own
  closing line — that it evaluates nothing — is the first thing commit 2
  removes.
- **The page says it evaluates nothing, in its own text.** Without that line a
  reader cannot tell "this rung computes no estimate" from "the curve is
  missing", and the same move is already made for the domain's silence one
  section up. A decision stated beats a gap inferred.
- **The gate did not grow.** 163 Swift tests green and unchanged, because no
  Swift was added. 56 Python — 31 before (16 fit, 15 serve) and 25 new (10
  route, 15 renderer). Both iOS builds succeeded. Drift green with all four
  assertions quiet.
- **Measured, because the run produced it:** the rendered page is 11,177 bytes
  for the committed artifact, and `curl -I` reports the same `Content-Length`
  on HEAD as GET's body length. `GET /v1/model | diff - Fit/model.json` came
  back empty, unchanged by the second route.
- **Not measured yet, as a trigger rather than a someday.** Request latency,
  throughput, behavior under concurrent requests, the per-request
  read-and-render cost, startup and decode cost. What kept these off the list
  was "there is no consumer"; there is one now, so the condition is written
  instead: **they are measured when the service is run for a reader on a
  machine that reader does not operate — the first moment a figure describes
  an experience rather than a loopback round trip — and a registered workload
  exists to measure against, so the number is reproducible rather than one
  anecdote.** Before both, a millisecond from a local GET is decoration. The
  ROADMAP paragraph that gave the old reason was corrected in this commit.
  The command an operator runs is unchanged and now prints two URLs:
  `.venv/bin/python Fit/serve.py Fit/model.json`.

## 2026-08-13 · v0.8 commit 2 — the refuser, the registered ladder, and the evaluated column

**Built and gated.** The page evaluates now, and the two things it needed
first were a ladder that is actually registered and a refuser that is not
`predict`.

- **The ladder was not registered, and this commit gave it the status its
  comment already claimed.** `ModelProbe.swift:23` read "The registered ladder"
  while the v0.7 entry above says the ladder "is a probe-local choice and is
  not registered anywhere." DEVLOG was right by this repository's meaning of
  the word — written before use, in a place that binds — so the fix was to
  register it rather than to soften the comment. **This entry is the
  registration.** `fit.DEPTH_LADDER` is the declaration, `view.py` imports it
  the way it already imports `fit.CLASS_NAMES`, and Swift carries the same
  eight numbers because it cannot read a Python constant. One source and one
  mirror: a symmetric pair of literals has no owner, which is why "both sites
  carry it" was not enough.
- **Three alternatives, and why each lost.** A committed data file both read is
  a new read path in two languages for eight numbers, and it moves the ladder
  out of the block each reader's own comment sits in. This entry alone, with no
  mechanical check, leaves the agreement as prose that only a human diffing two
  outputs would catch. Not sharing it at all discards the free drift detector
  and the reason commit 1 registered the reuse. A **derived** ladder — band
  edges plus a point outside each end — was considered and lost on its own
  merits: `BAND_EDGES` has no Swift twin, and deriving it there from the
  artifact's table would make a deterministic block artifact-dependent and
  undefined when no class is refused.
- **The check reads the Swift declaration from the Python suite, and the
  precedent is not `rfile`.** It is `ModelArtifactTests`, whose own comment says
  copying `Fit/model.json` into `Tests/` "would create a second copy to drift"
  and which therefore reaches across the tree from the test — same problem,
  same answer, opposite direction. `rfile` and `://` are negative-existence
  sweeps whose failure mode is passing silently; this is a positive assertion
  on one declaration whose failure mode is going red. A reformatted declaration
  going red is the price of never having a silent green, and the price is worth
  paying in that direction.
- **Not a fifth drift assertion, for a reason inside the script.**
  `Scripts/readme-drift.swift` opens "Fails when the README contradicts the
  repository" and every failure it emits is formatted `README claims "…" -- …`.
  Two source files disagreeing about eight numbers has no README end to anchor
  to, and README's own line — "The third fails when this README contradicts the
  repository" — would have gone stale in the commit adding a check against
  staleness. The Fit suite's cost is real and is named rather than waved past:
  the argument that kept the gate at five commands was that these tests live
  beside the fit and one `discover -s Fit` finds them, and a cross-tree read
  erodes that slightly. It is the smaller price. The `fit` job checks the whole
  repository out, so the Swift file is there.
- **The path is anchored to `__file__`, and that is load-bearing rather than
  tidy.** The check fails rather than skips when the declaration is missing, so
  a path resolved against the caller's working directory would turn "run from
  somewhere other than the root" into a red that reads exactly like "someone
  moved the declaration" — destroying the one thing this check exists to say
  unambiguously. `test_serve.py`'s `HERE` is the shape it copies.
- **Two questions over one pair of endpoints, said precisely.**
  `POSITIVITY_GRID` is closed and asks *may this candidate be adopted*: a form
  that goes non-positive at 5.0 m is disqualified whether or not any consumer
  asks there. `ANSWERING_DOMAIN` is half-open and asks *does this consumer get
  a number*, the reading `Sources/Model` resolved from the banded table's own
  arithmetic, where the last band is `[3.0, 5.0)` and 5.0 falls in none. It is
  an **alias**, not a second pair — the two names are one object, the
  half-openness lives in `estimate`'s comparison and in the comment, and a
  reader who greps `DEPTH_DOMAIN` still lands on both uses. What enforces the
  difference is `test_the_two_domains_disagree_at_the_top_endpoint`, which pins
  5.0 on the gate's grid and refused by the refuser.
- **The refuser is a second implementation of refusal semantics, which is a
  heavier thing than a second arithmetic would have been.** `fit.predict` is a
  shared evaluator and deliberately not a shared refuser: it answers at 6.0 m
  where `ModelProbe` refuses, and its table path returns one bare `NaN` for two
  findings the Swift type keeps apart. `fit.estimate` mirrors `Estimate` case
  for case, in plain dicts, with no new import. **Four cases and no fifth**: an
  unnamed verdict, a form the module has no arithmetic for, and a table that
  does not span the domain all raise, exactly as `predict` raises on an unknown
  form. Inventing an unnamed silence here would be, in the other language, the
  failure that enum exists to prevent.
- **What the page does when the refuser raises.** It prints a sentence and no
  number, and still shows everything the artifact carries for that class —
  verdict, coefficients, folds — which is the same rule that already renders a
  form `FORMULAS` cannot name. Refusing to invent an estimate is not the same
  as hiding what the artifact says.
- **The closing line came out first, as registered, and what replaced it.** The
  page no longer says it evaluates nothing. What survived the edit is the half
  that is still true and still load-bearing: every depth is the repository's
  own, no depth a viewer chose is on the page, and making them selectable needs
  either a script in the browser or a query parameter — neither of which this
  service accepts. The domain's silence stays stated above the classes, and the
  ladder's own out-of-domain cells are worded as the **domain's** refusal, so
  the two silences still cannot collapse into one another.
- **Both teeth shown red first.** Making the answering domain closed — 5.0
  answering — turned **five** test methods red across both files, and four of
  them were errors rather than failures: with 5.0 admitted, the refused class
  falls in no band there and the page stops rendering a ladder at all, which is
  the fifth silence arriving exactly where the two-domain argument said it
  would. Rendering a band without samples as `0.000000` turned **two** red,
  including commit 1's own band test, and the failure message shows the zero in
  the ladder row beside the band table still correctly reading `no samples` —
  the tidy-looking version of the bug. Both were restored and both files
  byte-compared against their pre-inversion copies.
- **One assertion was written wrong and caught by its own red.** The replaced
  closing-line test first swept the whole page for "evaluates nothing" and went
  red on the shell's hand-written comment that the **browser** evaluates
  nothing — a different claim, still true. It now asserts the removed sentence
  by its distinctive words, with a note saying why the wider sweep is not
  wanted. This is the `://` fragility appearing in a test written the same week
  it was described.
- **The fold table's overflow, found visually and not by a test.** The terminal
  verified commit 1 as extracted text, so nothing saw that at the default width
  the column falling off the card was `quadratic` — the adopted form — and the
  value clipped was its margin, the evidence this rung gave a sign on purpose.
  Holdouts now print their first UUID block, as this log already writes them,
  with all four full identifiers still on the page under TRAINED ON. A name
  that is not UUID-shaped prints whole: shortening an arbitrary one could make
  two rows read identically, and each row is a different container's evidence.
  No `title` attribute — it would put the full identifier back in the markup
  for no rendered gain.
- **`ModelProbe.fixed`'s docstring was fixed first, in `15e4c25`, not here.**
  Recorded found-not-fixed by commit 1; it claimed the margin its call site
  never sends it. It is not this commit's concern — line 23 changes *because*
  the ladder's status changed, while 177 was unrelated staleness — and one
  concern per commit was never one file per commit.
- **The gate did not grow.** 163 Swift tests green and unchanged: the only
  Swift edit is a comment, and a comment is not a test. Python 56 → **71** — 16
  fit becomes 24 (six refuser, two ladder), 15 renderer becomes 22 (five
  ladder, two holdout, one rewritten in place), 25 route unchanged, and the
  arithmetic closes. Both iOS builds succeeded. Drift green with all four
  assertions quiet, and README is untouched: nothing it claims about the page
  became false, and "every depth on that page is the repository's own, fixed in
  the tree" is what the registration above finally makes checkable.
- **Not measured yet.** Request latency, throughput, behavior under concurrent
  requests, the per-request read-and-render cost. Commit 1's trigger stands
  unchanged and this commit does not trip it: nothing here was run for a reader
  on a machine that reader does not operate, and no registered workload exists
  yet. The page grew by a table per class and that size was not measured either.

## 2026-08-13 · v0.9 commit 1 — the sighted point, and the span it refuses

**Built and gated.** The ladder ended one commit ago, so this rung had to earn
reopening it rather than assume it. The whole of the case, and the only thing
offered: the fitted model exists, a Swift reader for it exists, and the person
who needs both is holding the phone.

- **Reopening a finished ladder is legal here, and the checker was built to
  say so.** The v0.8 close argued that inventing a rung to keep an assertion
  green inverts this repository's discipline. That argument cuts both ways: a
  rung arriving because there is a reason is the honest case, and
  `readme-drift.swift:119` already encodes the difference — a non-`done` row
  makes `ladderHasEnded` false and re-arms the row requirement in the same
  edit. What would have been drift is a rung *invented* to refill the table;
  what happened is the ROADMAP's own "each rung is pulled in by the one below
  it". The one below it is v0.7's endpoint and v0.8's page, both of which
  serve a reader sitting at a laptop.
- **The documents could not be split into the customary pair, and that decides
  the commit shape.** Every earlier boundary landed as `docs: close v0.N in the
  readme` then `docs: move v0.N into the roadmap's shipped list`, two commits,
  because each half was independently green. Here neither half is: a README
  ladder row without the ROADMAP row fails assertion 2 at
  `readme-drift.swift:157`, and the ROADMAP row without the ladder row fails at
  `:165`. Splitting would commit a red gate on purpose. One commit, both files,
  and the precedent is only apparently broken.
- **The name is not `measure`, and `point` is crowded on purpose.** `v0.4
  measure` exists and assertion 2 pairs ladder names with ROADMAP names, so a
  second `measure` would be legal and unreadable. `point` names the estimand's
  granularity, which is the decision this rung lives on. But this repository
  already says "44,973,892 points", "depth pixels into world points" and "a
  point-cloud reader", so the word cannot stand alone anywhere it appears — the
  ladder line, the table row and the attach map all carry a description that
  disambiguates in the same breath. Runner-up `sight` is the better name on this
  project's own lineage (a surveyor *takes a sight*; Skewline is named for the
  common perpendicular of two rays that should meet) and lost on one thing: a
  stranger parses `point` in one beat and stops at `sight`. It became the
  module's name instead, which leaves it available if the collision reads worse
  later than it does now.
- **The model describes a point, not a span, and that is registered before any
  UI exists.** The obvious feature is a tape measure printing `1.42 m ± 0.03`,
  and it would be the largest overclaim in this project's history. The estimand
  is the upper median absolute cross-frame reprojection disagreement of **one**
  point at k=1; an interval on the separation of two points needs an
  error-propagation rule never derived here and a correlation between the two
  points' errors never measured. Adding it silently would undo v0.4 through v0.8
  in one label. The trigger has two gates, not one, and the second is the
  interesting one: `Calibration.Observation` carries separation, Δt, class,
  depth and residual and **no frame identifier and no pixel identity**, so two
  observations cannot be known to come from one frame pair. The correlation is
  not computable from any export this repository has ever produced, and the
  export that could compute it — per-pair per-pixel rows — is much closer to
  reconstructable than the aggregates the privacy line permits, so it needs a
  privacy decision before it needs code. The span is not "not done yet"; it is
  blocked behind something deliberately never collected, which is the shape v0.7
  gave capture upload.
- **That refusal is documentary, and saying so is the honest part.** v0.7 could
  write "enforced by the router rather than promised" because a 404 is a fact.
  There is no equivalent here: `Estimate` hands out a `Double` and nothing stops
  a caller subtracting two of them. What enforces the refusal is that no API
  takes two points and no surface offers a span. Letting "refused" imply a guard
  that does not exist would be the same overclaim one level up.
- **The span is not the only overclaim, and the other one is invisible.** The
  artifact guards **depth** — outside `[0.5, 5.0)` every class refuses — and
  guards **scene** not at all, because it cannot: the fit is leave-one-out over
  four recorded sessions, so a number read live in a fifth room is an
  extrapolation across scenes, not across depths. A tape measure a careful
  reader catches; this one they would not, which makes it the more dangerous of
  the two. So the on-screen wording is registered here with the same care as the
  span: not "this point disagrees by X" but a form carrying where the number came
  from — *on the four sessions this was fitted from, two views of a point like
  this disagreed by about X*. `SightProbe.say` is that wording, in code, and its
  doc comment says every consumer of this module owes its reader the same.
- **Planar z, and the fifteen per cent a raycast would cost silently.** The
  fit's `depth` column is `Calibration.swift:514`'s `source.depths[index]`: the
  raw `ARDepthData.depthMap` float, unmodified. ARKit's entire shipped text is
  "per-pixel depth data (in meters)"; the deciding source is Apple's point-cloud
  sample and `constantDepthMapUnprojectsToConstantCameraZ` locks it. That was
  recorded at v0.3 as a geometry decision. On a phone it becomes a trap: the
  obvious implementation of a tap is an `ARRaycastResult` distance, which is ray
  length, and ray length exceeds planar z by `1 / cos` of the angle off axis —
  about fifteen per cent at thirty degrees, with the model then applied to a
  depth it was never fitted on and a plausible number coming out. Naming the
  parameter `depthMeters` and documenting it as the depth map's own sample is
  the only guard there is; there is no type that can tell the two `Float`s apart.
- **A seventh module, and the cheaper alternative said out loud rather than
  waved past.** The alternative is real: `Sighting` as an extension in `Model`
  with a comment, `DepthMapGrid` beside `Unprojector` in `Render`, zero
  documentation churn. It loses on three counts, and the first one is that *the
  dependency argument does not decide it* — an extension taking a `UInt8` never
  reaches for `Render`'s `ConfidencePoint`, so nothing in `Package.swift` is
  literally violated. What decides it is what a module is allowed to *know*:
  `skewline-fit/1` names its classes `low`/`medium`/`high` and says nothing
  about 0/1/2, an encoding that is `ARConfidenceLevel`'s and enters this
  repository through `Capture` and `Render`. A reader whose discipline is to
  believe nothing the artifact does not say should not carry a sensor fact the
  artifact never mentions. Second, the split leaves the composition homeless,
  with no probe and no one place to test it, and makes the eventual client link
  `Render` — Metal, shader bundle and all — for two pure functions. Third,
  `Model` already named this boundary and declined to own it, calling it the
  consumer's edge; this rung builds that consumer. The bar is one this
  repository set: `Model` itself shipped in `7f8ad02` as a `.library` with
  exactly one consumer, `ModelProbe`, and no app links it to this day.
- **Two silences the sensor makes, kept apart from the two the model makes.**
  `Sighting` nests `Estimate` rather than flattening into five cases. A pixel
  that returned no depth and a confidence class the fit never saw happen
  *before* the model is consulted; outside the fitted depths and inside a band
  with no samples are the model's own. Flattening would say the two kinds are
  one kind, which is the collapse `Estimate`'s four cases exist to refuse.
  Depth is checked before class, because a pixel with no return has no reading
  and whatever class the sensor stamped on it describes nothing. And the class
  map is a `switch` with three written cases rather than a subscript into
  `allCases`: the order is the same, but an array index would carry the mapping
  in a coincidence of declaration order, and this mapping is the one thing here
  that could be wrong with nothing going red.
- **The half-open rule, now on the image plane, and one clamp that is not
  decoration.** `DepthMapGrid.pixel(atNormalizedX:y:)` is `0 <= x < 1` and
  truncating — the same convention `Range<Double>` gives the depth domain and
  `low <= d < high` gives the bands. It also clamps, which looked redundant and
  is not: the product of a normalized value a hair under 1 and the extent is
  *rounded*, and for some extents it rounds up to the extent itself and
  truncates one past the end of the buffer. `aValueAHairUnderOneNeverIndexesPastTheEnd`
  walks 1…600 rather than asserting the clamp is unreachable. The other half of
  a tap — `ARFrame.displayTransform(for:viewportSize:)` — stays out, because
  only ARKit knows it and it is not the half that can be wrong quietly.
- **v0.7's per-point refusal meets the first client that genuinely has
  per-point questions.** The service answers no per-point query, because "how
  wrong is a reading at this depth" would send the asker's own depths up the
  wire. Every consumer so far had aggregate questions; a phone pointed at a wall
  has exactly the question the endpoint refuses. The refusal holds by
  construction rather than by restraint: the artifact comes down whole and is
  evaluated locally, no depth, point, pose or frame goes up, and there is no
  endpoint that would accept one. Verified rather than inherited — `Sources/Model`
  is three files, all `import Foundation`, no `#if` of any kind, no target
  dependencies, and the iOS build already compiled it before this commit.
- **Where the live surface goes is bounded, and `README.md:84` has a third
  reading nobody had checked.** The rung is committed to a client on the device
  that fetches `/v1/model` and consumes it locally — registered here on v0.7
  commit 1's precedent of registering a Swift client it did not ship. But
  README says the harness "should not grow a second job", and that is a claim
  this repository keeps true. Read the clause before it: *put the pipeline in
  front of real sensors and produce containers a Mac can replay*. Showing what
  the model says about what the sensor is seeing right now is that pipeline in
  front of real sensors, end to end, since the fitted model is the pipeline's
  own output. What that sentence refuses is a **measuring tool** — pick two
  points, keep a history, export. On that reading the harness gains a `Model`
  link and a line on its existing panel, and README needs a narrowing clause
  naming what a second job would be, rather than a rewrite or a second app
  target the gate's third command would not build. Which branch is taken is
  decided in the commit that builds it, which is what the divider restored
  above says.
- **RealityKit rather than Metal, argued on what the feature needs.** Camera
  passthrough, a tap, a 2D overlay; no anchors, no 3D content, no occlusion, no
  mesh. `ARView` is passthrough with no rendering code. The Metal in this tree
  is an offscreen point-cloud shader for replay with measured numbers behind it
  and is not a camera-background pass, so "Metal is already here" does not
  transfer — choosing it means a YCbCr background pass and its shader with
  nothing measured behind either. A rung-level decision, not a commit-level one.
- **My brief said RealityKit would be the first framework the gate cannot check
  on a Mac. It is not.** ARKit already is: `SensorSource` and `SessionRecorder`
  are type-checked by the second and third gate commands and run by nothing, and
  the app target has never been inside `swift test`. RealityKit adds no new gate
  cost. The clause was struck rather than softened.
- **The gate did not grow.** Five commands, unchanged. Swift 163 → **180** — 17
  in `SightTests`, nine on the sighting and eight on the grid. Python 71
  unchanged, because nothing in `Fit/` was touched. Both iOS builds succeeded,
  and the package build compiled `Sight` and `SightProbe` for the device without
  a guard, which is the claim about `Model`'s portability being inherited rather
  than re-argued. Drift green with all four assertions quiet, including the two
  this edit aims at: the `done` marks are still a prefix, one `here` row sits
  immediately after them, and the what-is-next table's row names the same rung
  the ladder does. README gained a module bullet and a count, `Six` to `Seven`.
- **Not measured yet.** Request latency, throughput, behavior under concurrent
  requests, the per-request read-and-render cost, startup. v0.8 commit 1's
  trigger stands and this commit does not trip it: a phone fetching from a
  laptop is the first half of that condition, and it has not happened here —
  nothing was run for a reader on a machine that reader does not operate, and no
  registered workload exists to measure against. The probe's timing line is a
  local read of a local file, which is the decoration that trigger exists to
  refuse. Nothing about the depth of a sighted point, its accuracy, or how often
  a tap lands on a pixel with no return was measured either, and no such number
  appears anywhere in this commit.

## 2026-08-13 · v0.9 commit 2 — the interface the operator names

**Built and gated.** The blocker on this rung was never the screen. `Fit/serve.py`
bound loopback with no flag to change it, and a phone cannot reach a loopback
socket on a laptop — so the first decision here is whether a registered constant
moves, and v0.7 wrote that constant as a decision rather than a default, which
makes changing it a re-registration and not a config tweak.

- **The flag, and why it is not a new default.** `--host ADDRESS`, in the same
  hand-rolled argument loop `--port` already lives in, defaulting to `BIND_HOST`.
  That shape is the whole argument: the safe value is what an operator gets for
  saying nothing, and reaching the network costs an explicit act. v0.7's own
  words survive intact — the default is still a privacy decision, not a
  convenience — because the flag does not move the default, it only makes the
  other choice sayable. No environment variable, no auto-detected address, no
  "if it looks like a LAN" heuristic: every one of those is a default this
  repository would be choosing on the operator's behalf.
- **What lost, and it lost on honesty rather than effort.** The alternative was
  to keep loopback and ship `Fit/model.json` inside the app bundle. It builds,
  and it is a lie by omission: the phone would be reading a copy rather than
  consuming an API, `ModelClient.fetch` would be dead code on the device, and
  the `unreachable` silence would be a case no client could reach. The rung's
  registered claim is that a Swift reader exists and the person who needs it is
  holding the phone. A bundled copy satisfies that sentence and not its meaning.
  A tunnel is the same trade with more moving parts and a second thing to
  explain.
- **Four texts asserted the old unconditional fact, and none of them is drift-
  checked.** `Scripts/readme-drift.swift` has no assertion that fires on any of
  these, so each was a human edit or it rots silently. The comment at the
  constant said "no flag exists to change it" and became false in the same diff
  that added the flag — rewritten, not softened. `README.md`'s "bound to
  loopback" was unconditional prose and is now conditional. The test is item
  four and has its own bullet. Naming them as a set was worth more than fixing
  them one at a time: the count is the finding, not any single edit.
- **`test_the_bind_host_is_loopback` was kept and renamed rather than deleted.**
  It is the only mechanical guard the privacy default has, and deleting it to
  make room for a flag would trade the guard for the feature it guards. It is
  now `test_the_default_bind_host_is_loopback` — the name had to say which of
  the two it holds, because the constant stopped being the only value the same
  day. Its sibling, `test_a_non_loopback_bind_requires_an_explicit_argument`,
  is the new half: it drives `parse_bind` over argument lists that omit
  `--host` and requires loopback back. Opt-in is now mechanical rather than
  promised, which is the same move `test_no_route_reads_a_request_body` makes
  for the wire.
- **The parse and the startup lines are pure functions, for the reason the
  router already is.** `parse_bind` and `startup_report` have no socket in
  them, so what a non-loopback bind *tells* the operator is testable without
  binding anything anywhere — the split `resolve` made in v0.7, applied to the
  driver. Five of the seven new tests never open a port.
- **A printed URL that cannot be typed is worse than no URL.** Bound to
  `0.0.0.0` the old interpolation would have printed
  `http://0.0.0.0:PORT/v1/model`, and that line is exactly what an operator
  reads and types into a phone. It now prints as bound *and* says plainly that
  a wildcard is every interface rather than an address a client can use. The
  fix that was refused: discovering this machine's address and printing that
  instead. It picks an interface nobody chose, on a multi-homed machine it
  picks wrong, and it reinstates by inference the default the flag exists to
  make explicit. Saying "this one does not work" is the smaller claim and the
  true one. IPv6 literals are bracketed — RFC 3986 section 3.2.2, because
  `http://::1:8000/` parses as neither host nor port.
- **The privacy paragraph moved, and one third of v0.7's was wrong to inherit.**
  v0.7 recorded that "any real deployment's log carries client address, user
  agent and timestamps". Two thirds transfer and one does not:
  `BaseHTTPRequestHandler.log_message` has *always* logged the client address
  and a timestamp to stderr, so a LAN bind is not the first time that happens —
  it is the first time the address is anything but `127.0.0.1`. **User agent is
  not logged at all**, then or now: the handler logs the request line and never
  the headers. Repeating v0.7's phrasing wholesale would have overclaimed the
  exposure in the direction of alarm, which is the same failure as overclaiming
  it in the direction of comfort.
- **Who can reach it, said next to why that is tolerable.** Not "the phone":
  anyone who can reach this machine on that network can read the model and the
  page, with no credential, for as long as the process runs. That is acceptable
  because **nothing served is private** — v0.7's finding, restated rather than
  quietly inherited, since the artifact is already in a public git repository
  and auth over it would be theater — and because nothing goes up. The two
  sentences are printed in the same warning on purpose. Apart, the first reads
  as a dismissal of the second.
- **The warning fires every run, not once at the flag.** The reach is a
  property of the process while it lives, and the operator is the only one who
  can end it.
- **A bind failure is answered rather than traced.** The likeliest new operator
  error is an address that is not on this machine, and a typo deserves a
  sentence rather than a stack. Exit 64, the same as the argument loop's:
  both are fixed by running the command again differently.
- **The gate did not grow.** Five commands, unchanged. Swift 180 unchanged,
  because no Swift was touched. Python 71 → **76**. Both iOS builds succeeded.
  Drift green.
- **Not measured yet.** Request latency, throughput, behavior under concurrent
  requests, the per-request read-and-render cost, startup. This commit does not
  trip v0.8's trigger and gets closer to it than anything before: the service
  can now be reached by a machine its reader does not operate, which is the
  first half. The second half is a registered workload, and none exists. No
  number about the flag, the bind, or the wire appears anywhere in this commit.

## 2026-08-13 · v0.9 commit 3 — one sentence, two readers

**Built and gated.** `SightProbe.say` was the registered wording and it lived
inside an executable target, which the app cannot import. A screen was about to
need the same six sentences, and the only way to have them was to write them
again.

- **Moved rather than copied, on the argument this repository has already made
  twice.** A second reader of the artifact is how two readers drift apart; that
  is why the service shares `fit.read_artifact` and why the page renders
  server-side instead of parsing the schema in a browser. Words drift the same
  way schemas do, and the failure is worse rather than milder: a refusal worded
  two ways is two findings to a reader who meets both, and nothing goes red.
  `Sighting.sentence(from:)` lives in `Sight` and `ModelReadError.Kind.name`
  lives in `Model`, each beside the type it describes.
- **The registered wording had no test at all.** That is the finding of this
  commit, and it was invisible until the move: `say` and `name(of:)` were
  `static func`s on a `@main` struct, so nothing in `swift test` could reach
  them, and the plan's claim that "the existing tests are the proof" was simply
  wrong. Eight tests arrive with the move — six pinning sentences, two pinning
  names — and they are what makes the *next* commit's change to the wording
  visible rather than quiet.
- **Pinned against a synthetic model, not the committed one.** `SightTests`
  already keeps that rule so a refit cannot turn it red, and the wording tests
  inherit it. `ModelFixture.artifact` gained a `trainedOn` parameter to make it
  possible: the sentence names a session count, so a fixture that cannot vary
  the count cannot test the clause that matters most.
- **Two of the eight are properties rather than strings.**
  `noSentenceHandsBackANumberWithoutItsProvenance` walks all three classes and
  requires the sessions clause on every branch that carries a number, and
  `everyRefusalHasItsOwnName` requires thirteen distinct non-empty names. A
  string comparison pins today's wording; these two pin the rule the wording
  exists to serve, and a fourteenth `Kind` added without a name goes red on the
  second without anyone remembering to add a case.
- **Output is unchanged, and that was checked rather than asserted.** Every
  string survived the move byte for byte; the only edit is `fixed` becoming
  `Self.fixed` at two call sites, which is a spelling and not a character on
  anyone's terminal. The commit says `feat` because two modules gained public
  API, not because behaviour moved.
- **One wart found and deliberately not fixed.** The sentence says "on the 1
  sessions this was fitted from" for a single-session artifact. `fit.py` refuses
  to fit fewer than two containers, so no artifact this repository can produce
  reaches it, and writing a plural rule for an unreachable case would be
  inventing a case. Recorded here instead, which is what this file is for.
- **The gate did not grow.** Five commands, unchanged. Swift 180 → **188**.
  Python 76 unchanged, because nothing in `Fit/` was touched. Both iOS builds
  succeeded. Drift green.
- **Not measured yet.** Unchanged from the commit before: request latency,
  throughput, behavior under concurrent requests, the per-request
  read-and-render cost, startup. Nothing here runs, and nothing here measures.

## 2026-08-13 · v0.9 commit 4 — the scale belongs to the reader

**Built and gated.** The registered sentence said "disagreed by about 0.004096 m",
and that is two claims that cannot both be right: either the digits matter, in
which case the hedge is noise, or a person is reading it, in which case the
digits are. This commit is the one that changes what a registered string prints,
and it is separate from the move for exactly that reason — a commit typed as a
pure move must not carry an output change hiding inside it.

- **One sentence, two scales, and the caller states which.**
  `Sighting.Precision` is `.meters` (six decimals, unhedged) or `.millimeters`
  (whole millimetres, hedged). The probe takes the first because `ModelProbe`
  and `fit.py` compare it digit for digit; the phone takes the second because
  this repository's own measured range runs from about 3 mm to about 200 mm, so
  a millimetre is the last digit a person can act on.
- **No default parameter, and that turned out to matter more than expected.**
  A default is how a screen ends up printing the machine's scale because nobody
  chose. Making it required meant the eight tests from the commit before failed
  to *compile* rather than failing to match — every caller was named by the
  compiler and none could keep the old scale by accident. A default would have
  turned the same edit into eight silent string mismatches.
- **The half-millimetre test found a real bug, and the fix is a rule this
  repository has already written once.** The guard was `millimeters < 0.5` on
  the raw value. `%.0f` rounds half to even, so exactly 0.5 mm cleared the guard
  and then printed `about 0 mm` — the one reading this number must never
  produce, since "0 mm" says the two views agreed. The guard now runs on the
  rounded value, which is the same correction `DepthMapGrid`'s clamp makes:
  a rule about the output has to be enforced on the output. Found by a test
  written for the boundary rather than by reading the code.
- **"under 1 mm" drops the hedge, because "about under" is not a quantity.**
  The bound is a statement, not an estimate.
- **A silence renders identically at both scales, and a test says so.**
  Precision is a property of a quantity and a refusal has none, so the four
  refusal sentences are scale-independent by construction. Pinning it stops a
  later edit from threading a number into a branch that has none.
- **The gate did not grow.** Five commands, unchanged. Swift 188 → **192**.
  Python 76 unchanged. Both iOS builds succeeded. Drift green.
- **Not measured yet.** Unchanged. No number here came from a run.

## 2026-08-13 · v0.9 commit 5 — the frame the phone read

**Built and gated.** A sighting on the device is only worth anything if it can
be checked, and checking it means running the same point through the same frame
here. The probe took the first frame carrying both maps and offered no way to
name another, so the phone's reading had nothing to be compared against.

- **`--frame N` names an index, which is not the same as choosing a frame.**
  The default's rule is unchanged and its reason still holds: picking the frame
  that answers best would be picking the finding. Naming one is the opposite
  act — the operator is repeating a measurement the phone already made, and the
  index is a fact about which frame that was rather than a preference about
  which frame answers. The two are visibly different in the report, which now
  prints `first carrying depth and confidence` or `named` beside the index.
- **Three refusals, kept apart rather than merged into one.** "No frame in this
  container carries both maps", "frame 9 is not in this container, which has 4"
  and "frame 1 carries no depth map and confidence map" are three different
  things to be told, and the last two are usually a transcription slip off a
  phone screen. `--frame` with nothing after it is a fourth. Collapsing them
  into one "bad frame" would be the same conflation this rung spends nine
  states refusing.
- **`--frame` may sit before or after the points.** One pass over the trailing
  arguments, because an operator copying an index and a point off a screen
  should not have to learn an order too.
- **No unit test, and the reason is structural rather than an omission.** The
  plan said "and the tests". `SightProbe` is an `executableTarget` with `@main`,
  so `UnitTests` cannot import it; no probe in this repository has ever had a
  Swift unit test, and giving one a test harness is a bigger change than a flag
  warrants. It was verified by running instead, against a synthetic four-frame
  container written for the purpose — frame 0 with no depth, frame 1 with depth
  and no confidence, frames 2 and 3 with both and different numbers, so the
  default and the flag disagree visibly. The generator stayed in the scratchpad,
  the same call v0.8 made about its capture driver and for the same reason: a
  committed generator would be tooling no gate runs.
- **What the run showed, and it is a check rather than a demonstration.**
  Against `Fit/model.json`: the default picked frame 2 and answered
  `0.006249 m` for a class-2 sample at 2.00 m, which is the high class's
  `[2.0, 3.0)` band median in the committed artifact; `--frame 3` picked a
  class-1 sample at 3.50 m and answered `0.044594 m`, which is medium's
  quadratic evaluated there. Both were checked against the artifact by hand
  rather than accepted because they looked plausible. The three silences and
  the off-the-map case were reached in the same run.
- **Exit codes stayed as they were.** 64 for anything the argument loop
  refuses, 1 for anything the container refuses. A flag that invented a third
  would be a convention arriving inside a feature.
- **The gate did not grow.** Five commands, unchanged. Swift 192 unchanged, no
  test being reachable. Python 76 unchanged. Both iOS builds succeeded. Drift
  green.
- **Not measured yet.** Unchanged. The probe's timing line is still a local
  read of a local file, which is the decoration v0.8's trigger exists to refuse.

## 2026-08-13 · v0.9 commit 6 — the point you tap, and the run nobody has made

**Built and gated, and NOT verified on a device.** The screen exists, the five
commands are green, and the by-hand check this rung's whole claim rests on has
not been run: it needs a phone and a laptop on one network, and neither was
available here. What that leaves unanswered is written at the bottom of this
entry rather than implied by its absence.

- **`README.md`'s third reading held, and the narrowing clause names the other
  two.** The sentence "it should not grow a second job" now says what a second
  job would be: a measuring tool — two points and the distance between them, a
  history, an export of its own. A single point the sensor is looking at now is
  the same job, because the model is this pipeline's own output. The clause that
  makes that more than an assertion is the last one: the frame being tapped is
  one the container keeps, so the reading can be re-derived. **A reading nobody
  can check would be the second job arriving in disguise.** No second app
  target, and gate command 3 still names one scheme.
- **The tap reads the frame the drain wrote, not the frame ARKit is showing.**
  This is the decision the whole commit turns on and it was nearly the opposite
  one. `arSession.currentFrame` is the obvious source and it is the wrong one:
  `SensorSource` strides frames and drops them under load, so the frame on
  screen is frequently one no container will ever hold, and a sighting taken
  from it could never be checked by anything. The drain publishes each frame it
  writes under the index the writer assigned, and the phone shows that index
  beside the normalized point — which are exactly the two arguments
  `SightProbe --frame N x,y` takes.
- **The slot holds bytes, and that is consistency with a standing rule rather
  than a new argument.** `SensorSource.swift:292-293` already says retaining an
  `ARFrame` starves the session's pool and stalls capture, and `:348` names
  holding ARKit's buffer across a yield as the thing its copy exists to avoid.
  A `Data` is outside that class entirely and crosses to the main actor with no
  `@unchecked` anywhere. `DepthEncoder.encode` already produced these bytes on
  its way to the payload and discarded them, keeping only their count, so
  handing them back costs no second pass over anything.
- **The bytes being the *written* bytes is what makes the check structural.**
  They are also tight-packed, `PixelBufferPacking` having stripped the row
  padding, which is what makes `DepthMapGrid.Pixel.index` a legal subscript at
  all: a `CVPixelBuffer`'s stride may exceed `width * 4`, and
  `row * width + column` against one is correct on the devices where the two
  agree and silently wrong on the rest. That is the mistake that would have
  made this rung wrong while looking right on the machine it was written on.
- **Two `ARView` facts, both of which fail quietly.** `ARView.session` has a
  setter (`RealityKit.swiftinterface:997` in the iOS 26.5 SDK), so it is handed
  the recorder's session rather than making a second one — two `ARSession`s
  cannot both hold the camera. And `automaticallyConfigureSession` is set
  **false** (`:1014`): left at its default, `ARView` reconfigures the session it
  is given, which would drop the `.sceneDepth` frame semantic `start()` sets and
  stop depth being captured with nothing going red. `ARView` conforms to
  `ARSessionProviding` and `UIGestureRecognizerDelegate`, not
  `ARSessionDelegate`, so `SensorSource` keeps the delegate slot.
- **`Sighter` is its own type because `SessionRecorder` says so.** That file's
  docstring reads "its only job is producing a container ... and it should not
  grow a second one". The model, the fetch and the reading are the second one,
  so they sit beside it rather than inside it.
- **Nine states, and the one that nearly collapsed.** A tap arriving with no
  ARKit frame first routed through `sight` with a not-a-number point, which
  lands on `.offTheMap` — and "nothing is running" is not "you tapped past the
  edge of the depth map". It got its own entry point. That is the same
  collapse `Estimate`'s four cases and `Sighting`'s three exist to refuse,
  reappearing in a UI convenience.
- **Unreachable and permission-denied are one state, deliberately.** iOS
  publishes no API for reading local-network authorization, and the preflight
  that exists — an `NWBrowser`/`NWListener` pair against a custom Bonjour type —
  costs an `NSBonjourServices` registration this app has no other use for and
  still cannot check silently, because the preflight is itself what raises the
  prompt. Declined. So the line names **both** causes and `ModelClient` now
  carries the `URLError` code into its message, which is the only evidence a
  reader gets for telling them apart. Naming two causes is more honest than
  inventing a check the platform does not offer.
- **No App Transport Security key ships, and that is the experiment rather than
  an oversight.** The plan began by assuming `NSAllowsLocalNetworking` was
  needed. It is not the right key for this: ATS does not govern numeric IP loads
  at all — Apple's own guidance is that the key "has no effect on IP address
  loads" and that on iOS 10 and later such loads are always allowed, the key
  covering unqualified and `.local` hostnames instead. Shipping it anyway would
  register a constraint that is not real, and no device run could have caught
  that, because with the key present a numeric-IP fetch succeeds either way. So
  the app ships with none and the run decides. `NSLocalNetworkUsageDescription`
  does ship, in both configurations beside the camera string, because a LAN
  request without it fails in a way that looks like a bug.
- **The address is typed, never guessed.** No hostname or IP enters this
  repository, and nothing browses for one. It is also not persisted, which is a
  small unkindness to whoever runs the check repeatedly and was left alone
  rather than turned into a stored default nobody asked for.
- **The gate did not grow.** Five commands, unchanged. Swift 192 unchanged --
  everything added here is in the app target, which has never been inside
  `swift test`, and that is a real gap rather than a boast: `Sighter`'s nine
  states are held by the compiler and by reading, not by a test. Python 76
  unchanged. Both iOS builds succeeded. Drift green.
- **Not measured yet, and now also NOT VERIFIED.** The measurement trigger is
  untouched: a phone fetching from a laptop is the first half of v0.8's
  condition and no registered workload exists, so no latency, throughput or
  concurrency number is owed or given. Separately and more importantly, **none
  of the by-hand checks has been run.** Unverified: that the phone reaches the
  service at all; whether a numeric IP works with no ATS key; which `URLError`
  a denied local-network permission produces and whether it differs from a
  service that is not running; that the nine states are reachable; that the
  frame counters still advance with `ARView` holding the session; and — the one
  the rung stands on — that the phone's reading and
  `SightProbe --frame N x,y` agree for the same tap. Until that last pair is
  recorded, this rung is built and not done.

## 2026-08-13 · v0.9 — the by-hand run

**Run, and recorded before the close touches anything.** This file is
append-only and a close never writes to it, so the run that decides whether the
rung may close is entered first and on its own. What follows is what happened on
a phone against a laptop, including the six checks that did not happen.

- **The pair, both lines verbatim.** Container `session-DDC15BC3`, 1367 frames.
  The phone:

      frame 1296 at 0.5326,0.5305  depth 1.27 m  class 2
      no form was adopted for this class; on the 4 sessions this was fitted
      from, its band disagreed by about 4 mm

  and `swift run SightProbe Fit/model.json <container> --frame 1296
  0.5326,0.5305` on the Mac, against the same frame, resolving to pixel
  136,101, the same 1.27 m and the same class 2, ending `by 0.004096 m`.
  They agree. 1.27 m in the `high` class lands in the refused table's
  `[1.0, 2.0)` band, whose median in the committed artifact is `0.004096031` —
  so `0.004096 m` and `about 4 mm` are one number at the two scales v0.9
  commit 4 split, and the two readers arrived at it independently.
- **This is the check the rung was built to survive, and it is the one that
  could have failed silently.** Had the tap read `arSession.currentFrame`
  instead of the frame the drain wrote, frame 1296 would have named a frame the
  container does not hold, and the probe would have answered about a different
  pixel with a plausible number. The agreement is evidence for the plumbing,
  not just for the arithmetic.
- **App Transport Security: no exception was needed, and none ships.** The
  phone fetched `/v1/model` over the LAN from a numeric private address with
  **no ATS key in `Info.plist` at all**, and it succeeded. That is the outcome
  the experiment was ordered to produce: had the key shipped, this run would
  have succeeded too and told nobody anything, because ATS does not govern
  numeric IP loads — `NSAllowsLocalNetworking` covers the named-host path,
  which is not the path taken here. The repository needed no security
  exception, which is a better sentence than any exception, and it is the same
  sentence the refused upload endpoint already earns.
- **Permission was granted; the prompt was not observed.** A successful fetch
  entails the grant and nothing more — whether this run showed the prompt or
  inherited a grant from an earlier install is not recorded, because nobody
  watched for it and, by this rung's own finding (`:2416`), the app has no API
  that could have watched for it either.
  `INFOPLIST_KEY_NSLocalNetworkUsageDescription` is set and is what a prompt
  would carry; that it carried it is unobserved too.
- **What still has not run, named rather than left to the absence.** Six of the
  nine row states were not reached: permission **denied** as against a stopped
  service — so **no `URLError` code is recorded and the two remain
  undistinguished**, exactly as the commit that built them predicted; a tap off
  the map; a pixel with no return; a class the artifact cannot name; a depth
  outside the domain; and a band without samples. They are held by the compiler
  and by reading, not by a run. The two that did run are the unreachable state
  before the address was typed, and the answer above.
- **The rung closes anyway, and the reason is that the condition was registered
  before the data.** `docs/DEVLOG.md:2453-2456` wrote it as "until that last
  pair is recorded, this rung is built and not done", naming one pair and not
  nine states. The pair is recorded. Raising the bar now because six states
  went unreached would be as much a move as lowering it would have been if the
  pair had disagreed, and registered criteria exist to forbid exactly that. The
  six are a written gap, not a renegotiated bar.
- **The gate did not grow.** Five commands, unchanged: Swift 192, Python 76,
  both iOS builds, drift green.
- **Not measured yet.** Unchanged, and this run does not trip v0.8's trigger.
  The service was run for a reader on a machine that reader does not operate —
  the first half — but no registered workload exists, so no latency, throughput
  or concurrency number is owed or given. Nothing here was timed.

## 2026-08-14 · v0.10 commit 1 — the seam two points share, and the criteria before the data

**Built and gated; every span number awaits the export and the fit.** The rung
opens on an argument rather than a feature. v0.9 refused an interval on a
distance behind two gates and wrote them down precisely enough that a later
rung could check whether they were *shut* or merely *unopened*. They were
unopened: the propagation rule had never been derived because nobody had tried,
and the missing seam turned out to be two integers and a displacement this
analysis already computes and throws away. This commit ships that seam and
registers both estimands, the rule, the criteria and the privacy decision —
before a single pair exists.

- **A refusal whose gates are one commit away is a finding about the refusal.**
  It only shows up because the trigger was written in advance and in enough
  detail to be falsified. The entry in *Deliberately not built* is edited
  rather than deleted, and the edit is deliberately **half**: the derivation
  clause goes, and "a correlation between the two points' errors that has never
  been measured" **stays**, because it is still true and stays true for nine
  more commits and a by-hand run. Writing the whole edit now would put a
  measurement claim in the tree ten commits before the measurement.
- **Two estimands, both registered now, because the data must not choose which
  question was asked.** AXIAL: the upper median of |r_b − r_a| for two
  same-class source pixels sharing one (source, target) frame pair at k=1,
  over the same statistic for partners matched on class and fine depth but
  drawn from a frame pair sharing no frame — the disagreement of a **depth
  difference** along the target camera's optical axis, dimensionless as a
  ratio, banded by lateral separation, never pooled. LATERAL: the upper median
  of the forward-backward round-trip displacement of those same pairs, in
  **depth pixels**, reportable only beside its truncation bound. The axial one
  is the floor and ships regardless; the lateral one may be refused.
- **The lateral quantity is censored by the filter that produces it, and that
  is the finding this rung turns on.** `forwardBackwardRadius` is a *gate*:
  every sample that reaches the sink has round-trip displacement inside the
  registered radius **by construction**, so the survivors' distribution is
  truncated from above and every statistic of it — the median included — is
  biased low. A lateral number computed over survivors without saying this
  would be a measurement of the filter, not of the sensor. This file already
  knows the shape of that problem: `Report.medianFocalLengthX` exists as "the
  denominator of the printed forward-backward truncation bound", and
  `SeparationResult` records that the fwbw variant "rides every k because its
  truncation bound tightens as the baseline grows". So the conversion from
  pixels to meters is not a new liberty either — it is arithmetic on two
  measured quantities that this file already performs for exactly this bound.
- **The rule, derived, and axial only.** `Var(r_b − r_a) = Var(r_a) + Var(r_b)
  − 2·Cov(r_a, r_b)`. The naive σ√2 is the `Cov = 0` case and is precisely the
  hypothesis under test; quoting it as the fallback when the test refuses would
  be the same overclaim arriving by the back door. `r` is planar z along one
  camera's axis, so this is a rule for one diagonal element of a point's error
  and **not** for a distance. Gate 1 is therefore recorded as partially open.
  Three further things it does not cover, named rather than left to the
  absence: the pixel-localization term (target depth is sampled at the
  *rounded* pixel, so part of a point's error becomes axial only through the
  local depth gradient); the conditionality (the covariance is conditional on
  the ten filters, and no argument is on file that it bounds the unconditional
  one); and distortion, which the pinhole model does not carry and which grows
  with separation just as the effect under test does.
- **The null is a permutation, not √2, and three things in the first reading of
  the physics were wrong.** A permuted partner leaves both marginals where they
  were and forces `Cov` to zero by construction, so the ratio is 1 under
  independence with no distribution assumed. Then: the rotation term depends on
  **lateral** separation only — `(δθ × ΔX)_z = δθ_x·ΔY − δθ_y·ΔX`, in which ΔZ
  does not appear — so the covariate is lateral camera-space separation in
  meters, and a ΔZ dependence would be a *depth-scale* error instead, a
  separable second prediction. "Cancels exactly" holds only for the predicted
  term: a translation error moves the sampled target pixel too, and `observed`
  moves with it through the local depth gradient, a channel that does not
  cancel and also grows with separation. And "the small-separation limit is
  sensor noise alone" is false twice over — depth-map noise is spatially
  correlated by construction, and at small separation two source pixels can
  round to **one** target pixel and literally share the `observed` value they
  are each measured from. The last of those is why `targetX`/`targetY` ride the
  seam: the collision rate has to be counted, not assumed away.
- **The matching is on fine depth and not on band, and that is not a
  refinement.** |Δ| grows with depth and neighbouring pixels have nearer
  depths, so a band-matched partner is drawn from a wider depth spread than the
  point it replaces — inflating the null, deflating the ratio, and
  manufacturing cancellation out of a scale mismatch. It is the difference
  between measuring the effect and inventing it.
- **Two thresholds are registered as `TODO(owner):` on purpose.** The lateral
  clearance and the cancellation margin each decide reportable-or-refused, and
  each gets its own name and its own argument in `Fit/span.py` rather than
  borrowing `Constants.orderingMargin`'s. That constant is real and is the same
  magnitude, but its registered question is "are two class error scales
  distinguishable", which is not "does a median sit clear of a truncation
  radius" — reusing the number avoids inventing one, and reusing the
  *justification* would be a coincidence of magnitude doing an argument's work.
  Neither value has a distribution-free derivation, because deriving one needs
  the shape assumption this rung refuses everywhere else, so both are judgments
  and are labelled as judgments. **They are filled in a commit of their own,
  before the first container is exported** — not merely before a commit lands.
  A criterion with an open threshold is not registered, and the hole is exactly
  where the data would walk in.
- **The sharpness condition has one registered reading, because it admits two
  opposite ones.** The replicate spread of the permuted denominator is a
  *measured* quantity, so "the margin must exceed it" could mean setting the
  margin from the observed spread — choosing a threshold with the data in view,
  the one thing this design forbids. It does not. The margin is set in advance,
  and the spread is checked afterwards as a **validity condition**: a margin
  that did not clear the null's own replicate spread means the comparison was
  never sharp enough to conclude anything, and the class is refused wherever
  the ratio fell. That reading can only add refusals and never manufacture an
  adoption, which is why it is the one written down.
- **The privacy decision, made before the code and not after it.** A `/1` row
  is five scalars with no address; nothing in the file says which two rows saw
  the same wall, which is exactly why v0.9 could not compute the correlation.
  Adding a frame index and a pixel supplies the join key, and joinable rows
  grouped by frame are a subsampled depth image — a labelled point cloud of
  somebody's home in all but the last arithmetic step. Arguing that as "two
  more integers" would be the dishonest framing, so it is not the one used. It
  is allowed by **confinement, not by any property of the file**: the export is
  written beside the containers, which already hold every depth map and pose,
  and it never enters the tree and never crosses the wire. Pose stays out
  permanently — it is the step that turns a stack of depth images into one
  cloud, and no statistic here needs it. One cost is paid rather than hidden:
  no reader can rerun this rung, so v0.6's reproducibility gap is inherited and
  widened.
- **The seam gained nine fields and no default values, and the audit that was
  supposed to fire found one caller.** Defaults were refused deliberately: a
  default would let a caller omit the identity that is the entire point, and
  compile errors are the cheapest possible audit of who constructs an
  `Observation` — step 33's argument about the precision parameter. The
  prediction was several compile errors. There were **zero**: the sink is the
  only construction site in the repository, and the tests read observations
  rather than build them. The audit ran and returned a smaller number than
  expected, which is worth recording as such rather than quietly enjoying.
- **Three traps, each of which yields a plausible wrong number rather than a
  crash.** The inner loop advances `x` by the stride *before* the filter
  cascade runs, so `x` at the sink names the next pixel — the source column is
  taken as `index % width`, which is what the round-trip check beside it
  already does, and for the same reason. `EligibleFrame` carried no session
  frame index and the enumerating loop discarded it, so it now stores one:
  exporting the *eligible* index would be a number silently meaning something
  different in every container. And `k` counts eligible frames, so
  `targetFrame − sourceFrame` is **not** always `separation` — the export
  exposes that for the first time, and the test asserts the ordering rather
  than the difference.
- **Five tests, and the one that matters was shown red first.**
  `theProjectedPixelIsTheOneTheResidualUsed` is the only new column whose
  wrongness is invisible downstream: a transposed `targetX`/`targetY` still
  produces plausible coordinates, a plausible separation, a plausible ratio and
  a plausible artifact. Transposing it at the emission site turned that test
  red with 60 issues while conservation, report-equality and pixel-uniqueness
  all stayed green — the division of labor, demonstrated rather than asserted.
  The fixture is 9×7 and the test ends by requiring a pixel whose column and
  row differ, so it proves it *can* catch a transposition instead of assuming
  it. Restored; 197 tests green, up from 192.
- **The gate did not grow.** Five commands, unchanged: Swift 197, Python 76,
  both iOS builds, drift green. The ladder reopened and the ROADMAP table
  gained its row in this same commit, because Assertion 2 couples them and
  splitting them commits a red gate.
- **Not measured yet.** Every ratio, every verdict, both thresholds, the
  export's row counts, file sizes and runtime. No container has been exported
  and no pair has been formed. v0.8's measurement trigger is untouched and
  stands on its remaining half: no registered workload exists, so no latency or
  throughput number is owed or given, and nothing here was timed.

## 2026-08-14 · v0.10 commit 2 — the sampling leaves the probe

**Built and gated; zero behaviour change, and the test is what says so.**
v0.6 put the every-Nth retention rule in the probe under the `InteropProbe
--dump` trade — untestable, and defensible for a counter. It is not defensible
for a sampling design a covariate rests on, and the rung below this one adds a
second rule beside it. So the rule moves into `Render` first, on its own, while
it can still be proved identical.

- **A move, not a change, and the difference is a test rather than a claim.**
  `Calibration.EveryNthSampler` and `Calibration.ObservationBucket` are the
  probe's own logic verbatim: one counter per (k × class × band), keep when
  that bucket's count so far is a multiple of the interval, survivor counts
  incremented for every observation and therefore pre-sampling. The probe's
  `ObservationCollector` now holds a sampler and formats rows; `decimation` and
  `survivors` became forwarding properties so the header writer is untouched.
- **The pin re-derives the rule rather than transcribing the implementation.**
  The test walks the real observation stream at four intervals, computes
  keep/drop from the rule's *words*, and requires the sampler to agree — plus
  that survivors sum to the full population, and that interval 1 keeps
  everything. A second test pins the phase: every bucket's first observation
  survives any interval, because the counter starts at zero.
- **Both were shown red, on the mistake that would actually be made.** Shifting
  the phase by one character — `(seen + 1) % interval` — turned the first red
  with 67 issues and the second with 2. That is the off-by-one a reimplementation
  invites, and it would have silently dropped the first sample of every bucket
  while leaving row counts almost unchanged.
- **The second test caught its own fixture before it caught anything else.**
  Written against the k=1 fixture it failed on its own guard: that container
  yields exactly one bucket, so it could not have shown that the counters are
  *per* bucket. Moved to the two-separation fixture. A test that cannot
  distinguish the thing it names is worse than no test, and the guard is there
  because assuming otherwise is easy.
- **The gate did not grow.** Five commands, unchanged: Swift 199, Python 76,
  both iOS builds, drift green.
- **Not measured yet.** Unchanged from commit 1. No container has been
  exported; the export's row counts, file sizes and runtime are still owed to
  nobody because no export has run.

## 2026-08-14 · v0.10 commit 3 — whole frame pairs, or none of them

**Built and gated; the sampling design the covariate rests on.** The span
statistic is banded by the separation between two points, and separation is a
*within-pair* quantity. That single fact decides the retention rule: thin at
the pair level and the covariate is untouched; thin inside a pair and it is
not.

- **v0.6's rule cannot answer this question, and not for want of columns.**
  Every-Nth keeps roughly every P-th survivor in the analysis's raster order,
  so consecutive kept pixels sit far apart in one row and the small separations
  are structurally unsamplable. Worse than a missing band: the comb is periodic
  in survivor index, so retained separations concentrate near multiples of its
  period — aliasing against the covariate rather than thinning of it — and
  because the edge mask removes survivors unevenly the period wanders, so it is
  not even an alias anyone could model out. No later statistic undoes that.
- **The replacement, in one sentence.** Keep every surviving pixel of every
  P-th frame pair; drop the other pairs whole. One knob, monotone in file size,
  and covariate-neutral by construction. The same row budget spent on all the
  pixels of a few pairs instead of a few pixels of all the pairs.
- **The ordinal counts pairs that delivered, and that is registered rather than
  incidental.** It is assigned on a pair's first delivered observation,
  per-separation, starting at zero. Pairs the Δt gate excluded, and pairs all
  of whose pixels were filtered, are not pairs this rule ever sees — which is
  the only definition a consumer of the sink's stream can compute, and it is
  written down so nobody later reads the ordinal as a frame number.
- **`P` must exceed the largest separation, and the sampler does not enforce
  it.** At `P <= k` two kept pairs share a frame, and then a permuted partner
  drawn from "a different pair" still shares a camera, a pose error and a depth
  map with the pair it stands in for — the null would be measuring the thing it
  exists to exclude. Only the caller knows which separations it asked for, so
  the caller checks, and the next commit is where that lands.
- **Shown red under the rule it replaces.** Making the sampler stride over
  observations instead of pairs — which is exactly v0.6's rule — turned the
  test red with 46 issues, the first of them "one pair was partly kept and
  partly dropped". A green test under the old rule would have meant the new
  sampling was not actually new, which is the only failure worth demonstrating
  here.
- **And the fixture is checked for the property the test needs.** A second test
  requires the container to contain more than one pair and at least one pair
  with more than one survivor; without both, "keeps whole pairs" is a claim
  about singletons. This is the second time in two commits that writing the
  guard first found something — it is cheap, and assuming the fixture is
  adequate is how a test passes for the wrong reason.
- **The gate did not grow.** Five commands, unchanged: Swift 201, Python 76,
  both iOS builds, drift green.
- **Not measured yet.** The registered value of `P`, the row counts and the
  file sizes it implies, and every span number. Nothing has been exported.

## 2026-08-14 · v0.10 commit 4 — the geometry export, behind its own flag

**Built and gated, and the plumbing was run end to end on one container.**
`--dump-geometry <out.csv> [--pair-stride P]` writes
`skewline-observations/2`: the `/1` header verbatim and in the same order,
then the pair-level sampling provenance, then one `# intrinsics` line per
exported source frame, then thirteen-column rows whose **first five are the
`/1` five, unchanged and in the same order**, so a reader that takes five
positionally still reads them.

- **Opt-in, and that is the privacy gate rather than an ergonomic choice.** A
  `/1` row is five scalars with no address. A `/2` row carries a frame index
  and a pixel, so grouped by frame the file is a subsampled depth image of
  whatever the sensor was pointed at. Widening the *default* export would have
  made every future dump reconstructable by accident; a separate flag means the
  reconstructable file only exists when somebody typed the word. The probe
  prints `privacy  per-pixel rows -- keep local, never commit` beside the path.
- **Three usage guards, all verified to exit 64.** One container per
  invocation, as `/1` already required, because one header binds one session.
  The two dump flags cannot be combined — two schemas through one analysis
  would produce two files whose sampling rules disagree while both headers
  claim the same run. And `--pair-stride` must **exceed** the largest
  separation: at `P <= k` two kept pairs share a frame, and the permuted null
  would then be measuring the sharing it exists to exclude. `--separations 1,5
  --pair-stride 5` is refused for that reason and not for being small.
- **`# decimation 1` ships even though this file decimates nothing.** Present
  and truthful rather than absent, so no reader has to branch on a missing key
  to learn that a `/2` file drops no survivor of a pair it kept.
- **The intrinsics table is a projection of the rows, and the smoke run proved
  it had to be per-frame.** Entries are written only for observations the
  sampler kept, so the header cannot describe a frame the file does not
  contain. The run's three exported frames reported three *different* focal
  lengths — ARKit updates intrinsics within a session — so a single header
  value would have been quietly wrong for two of the three, and the
  camera-space separation computed from it wrong with it.
- **One trap did not fire, and that is worth saying too.** Every row of the
  smoke container had `tgt_frame - src_frame == k`, because every frame in it
  was eligible. `k` still counts eligible frames rather than session frames, so
  the equality is a property of that container and not of the format; the test
  asserts the ordering of the two indices and never their difference, which is
  why it stays correct on a container with an ineligible frame in the middle.
- **The smoke run, in v0.6's shape: plumbing only, deleted, no number kept.**
  One container at a deliberately coarse stride, to prove the probe writes and
  the header parses. Its row counts, survivor counts and runtime are **not**
  the registered export's and none is recorded — reading a span statistic
  before the thresholds are registered is precisely the contamination this
  rung's ordering exists to prevent. The file was removed; nothing derived from
  it enters the repository.
- **The gate did not grow.** Five commands, unchanged: Swift 201, Python 76,
  both iOS builds, drift green.
- **Not measured yet.** Every span number, both thresholds, and the export's
  size at the registered stride. The `/2` rows are much wider than `/1`'s and
  the registered stride keeps whole pairs rather than every 64th survivor, so
  the file will be substantially larger; whether it is *unwieldy* is not
  measured, and `P` is the lever if it turns out to be.

## 2026-08-14 · v0.10 commit 5 — the privacy line, made mechanical

**Built and gated, and the guard was shown red four ways before being
trusted.** v0.9 wrote that its span refusal was documentary — "there is no
equivalent here: `Estimate` hands out a `Double`" — and said so plainly rather
than implying a guard that did not exist. This commit is the case where the
equivalent *is* available, so declining it would have been a choice.

- **What was holding the line until now was location and habit.** Observation
  exports live outside the repository and CLAUDE.md says stage named paths,
  never `-A`. That was tolerable while a mis-staged row was five anonymous
  scalars. It is not tolerable for a row carrying a frame index and a pixel,
  which grouped by frame is a subsampled depth image of a room — so the
  widening pays for the guard rather than inheriting the old one.
- **It is a README claim backed by a tree walk, which is Assertion 1's existing
  shape.** "No observation export is committed" now appears in the README, and
  the drift check fails while that sentence is present and any file under the
  root begins with an observation schema tag. Writing it as a claim rather than
  an unconditional scan is what makes it a *public promise* that is checked,
  which is worth more than a private rule that is enforced.
- **First line, not "contains", and that distinction is the whole check.** An
  export *begins* with its tag; source that merely mentions the tag does not.
  `Fit/fit.py` declares it as a constant and `Fit/test_fit.py` embeds a whole
  fixture whose first line is `# skewline-observations/1` — several lines into
  the file. A "contains" check would go red on the harness that reads the
  format, which is the one file that must be allowed to name it. One 256-byte
  read per file, because a tag is at the top or it is nowhere.
- **Both schemas are refused, because the rule predates the second one.** A
  `/1` export was never committable either; only nobody had written it down as
  something a machine could check.
- **Shown red on the tree, not on a unit fixture.** A planted `/2` file at the
  root failed the gate and exited 1; a planted `/1` file at `Fit/nested/`
  failed it too, so the walk is not depth-one; removing each restored green.
  And the clean tree passing is itself the fourth check — it proves the two
  Python files that contain the tag are not being flagged, which is the failure
  mode a careless implementation would have shipped.
- **The `.gitignore` lines are advisory and are labelled as such.** `git add -f`
  beats them; they exist so the common case never reaches the gate, not so
  anyone relies on them. The comment says which of the two is the guard.
- **The gate did not grow.** Five commands, unchanged: Swift 201, Python 76,
  both iOS builds, drift green. The drift check gained an assertion rather than
  the gate gaining a command.
- **Not measured yet.** Unchanged: every span number, both thresholds, and the
  export's size at the registered stride.

## 2026-08-14 · v0.10 commit 6 — one reader, two schemas

**Built and gated; the fit's own inputs are provably untouched.** `fit.py`
raised on a `/2` file — loudly, so there was no correctness emergency, only an
ergonomics one. It now reads either schema, and the tag alone decides the
width.

- **One reader and not two, for the reason `serve.py` and `view.py` already
  settled.** The columns the fit uses are the first five of either schema, so a
  second reader would be a second copy of the same positional agreement, and
  two copies of a positional agreement is exactly how one of them drifts. A
  tag→columns map replaces the hard-coded five; the returned dictionary is
  keyed by column **name**, so `load_class_containers` and everything
  downstream is untouched.
- **The freeze is asserted as an equality rather than described in a comment.**
  A test reads the same four rows in both schemas and requires every one of the
  five shared columns to compare equal. That is what "`/2` appends and never
  reorders" means operationally, and it is why `Fit/model.json` stays
  reproducible from the `/1` files it was fitted from.
- **The `# columns` line has been written since v0.6 and read by nobody until
  now.** Every consumer below it is positional, so a writer that quietly
  swapped two columns would have been a green suite and wrong numbers
  everywhere — the worst failure shape available here. The header is now
  checked against the registered order for its tag.
- **Shown red by swapping `depth` and `delta` in the registered constant.**
  Four tests errored and one failed, and the one that *failed* is the
  interesting one: `test_a_reordered_columns_header_is_rejected` stopped
  raising, because with the constant swapped the deliberately-bad header
  matched. That is the check working in both directions — it compares the file
  against the registration, so corrupting either side is caught.
- **Two small correctness fixes rode along.** The empty-file case built a
  five-wide array regardless of schema and now uses the tag's own width; and a
  `/2` tag on `/1` rows is refused rather than read as a narrow file that
  happens to be mislabelled, because the tag is what decides.
- **The `k`-counts-eligible trap is now pinned in Python too.** The `/2`
  fixture contains a k=5 row whose frame indices differ by 1, so a reader that
  assumed `tgt_frame - src_frame == k` goes red on the fixture rather than on
  somebody's container.
- **The gate did not grow.** Five commands, unchanged: Swift 201, Python 80,
  both iOS builds, drift green.
- **Not measured yet.** Unchanged: every span number, both thresholds, the
  export's size at the registered stride.

## 2026-08-14 · v0.10 — what the six entries left out

**Three corrections to the record, none of them to the code.** This file
records the mistakes and not only the decisions, and these are three places
where the entries above are thinner than the work was. Written as its own entry
because the file is append-only and a correction that edits history in place is
not a correction anybody can audit.

- **A real finding went unrecorded behind a rule that did not cover it.**
  Commit 4's entry says no number from the smoke run is kept, and that was one
  category too wide. The prohibition is on reading **the statistic** before the
  thresholds are registered — the ratio, the medians, anything that is the
  estimand or a step toward it. A focal length is *structure*, in the same
  category as "thirteen columns" and "the header parses", both of which were
  checked and reported. So the finding is recorded here with its provenance:
  container `2110CDA9`, one deliberately coarse stride, an unregistered smoke
  export since deleted, three exported source frames — 36, 436 and 836 —
  carrying focal lengths **190.41724, 178.35194 and 178.66602** depth pixels.
  ARKit updates intrinsics within a session. That is what turns the per-frame
  intrinsics table from foresight into evidence: a single header value would
  have been wrong for two frames of the three, and every camera-space
  separation derived from it wrong with it. **No span number is recorded**,
  which is the sentence commit 4 should have written.
- **`rt_dx`/`rt_dy` was argued in advance, not improvised during the work.**
  Two components rather than one magnitude, because a relative-rotation error's
  signature is directional — `δθ_x·ΔY − δθ_y·ΔX` — and a magnitude destroys it.
  That is a widening beyond the *brief*, which asked for one field, and it was
  written into the plan and reviewed before a line of it existed. The source
  comment carries the reason but not the provenance, and the distinction
  matters in a rung whose whole subject is which decisions preceded the data:
  "improvised during the work" and "argued in advance" are different claims,
  and only one of them is true here.
- **`P` is a third registered value, and it moves only where the margins do.**
  Commit 3 committed a default and commit 4 noted that the file at that stride
  will be large and that `P` is the lever. That framing was too casual. File
  size is not the estimand, but `P` decides **which pairs are in the
  analysis**, which sits nearer the criteria than the plumbing — and `span.py`
  refuses a file whose sampling header is not the registered rule, so a changed
  `P` is a re-registration rather than a tweak. It is therefore governed by the
  same ordering as `lateralClearanceMargin` and `cancellationMargin`: if it
  changes, it changes in the threshold commit, before the first real export,
  with its reason written down. Never between exports, and never after seeing
  one.
- **The gate did not grow.** Five commands, unchanged: Swift 201, Python 80,
  both iOS builds, drift green. Nothing here touches code.
- **Not measured yet.** Every span number, both margins, and `P`'s final value.

## 2026-08-14 · v0.10 commit 7 — how two residuals cancel, and the null that says so

**Built and gated, and the planted fixtures found a real error in the
statistic before any container did.** `Fit/span.py` forms pairs within one
frame pair, answers each with a depth-matched partner from a pair sharing no
frame, and reports the ratio per class per lateral separation band. Nothing is
fitted; every registered value is a module constant.

- **The null was pooled over depth, and that manufactured cancellation.** The
  first implementation drew one null for the class and compared every
  separation band against it — defensible-sounding, because a permuted partner
  genuinely has no separation of its own. It is wrong, and the planted fixture
  showed it: separation is `(pixel offset) × depth / focal length`, so a
  small-separation cell is populated by **near** points, whose residuals are
  smaller because |Δ| grows with depth. A pooled null sits above those cells for
  a reason that has nothing to do with cancellation. On a population with **no
  pair structure at all** it read ratios of 0.41, 0.42, 0.43 and 0.59 — a clean
  false positive, exactly where the real effect is predicted to be largest.
  Each null draw now rides beside the same-pair draw it answers and is binned
  by that draw's separation, so the two share a depth composition by
  construction. The same fixture now reads 1.03, 0.99, 1.03, 1.00, 0.99.
- **This is the failure the rung was built to avoid, caught by the method
  rather than by luck.** It is the same shape as the band-matching error
  already argued against in the module docstring, one level deeper: it is not
  enough to match the *partner* on depth if the *cells* are stratified by
  something depth drives.
- **A property of the estimand surfaced while writing the fixture.** The
  matched null needs depth **overlap between frame pairs that share no frame**.
  A first fixture gave each pair its own depth window, and the null came back
  empty: every depth-matched partner was necessarily from the same pair and was
  correctly rejected. A session that never revisited a distance would have no
  null and no answer — that is a real limit on when this statistic exists, not
  a fixture artifact, and it is recorded rather than engineered around.
- **Two guards were broken and stayed green, which is its own finding.** The
  frame-sharing rejection was first tested through `permuted_samples`, and
  breaking the guard on the path `cell_ratios` actually uses changed nothing.
  Then dropping the depth match changed nothing either, because the first
  fixture gave each pair iid depths — in a real frame pair the pixels sample
  one scene, so their depths are close. Both tests were rewritten against the
  real path and the real mechanism, and both now go red when the guard goes.
  **A red-first that passes is worth more than one that fails**: it named two
  tests that were describing behaviour they never exercised.
- **The guard reports two counters, and a test asserts both.** Zero
  shared-frame partners *used*, and more than zero *rejected*. Asserting only
  the zero would pass vacuously on any fixture where sharing never arose, which
  is precisely how a guard stays untested while looking tested.
- **Target-pixel collisions are rejected and counted.** Two source pixels can
  round onto one target pixel and then share the `observed` depth both
  residuals are measured from — a perfectly cancelling pair with no pose in it,
  concentrated at small separation. The fixture plants forty of them rather
  than two, because two left the count to chance and the point is the rejection
  rather than the draw.
- **No verdict exists yet, and asking for one raises.** `CANCELLATION_MARGIN`
  and `LATERAL_CLEARANCE_MARGIN` are `None`, not a plausible number, so
  `cell_verdict` refuses rather than quietly answering. A test asserts that
  refusal. They are filled in one commit before the first container is
  exported, and `P` with them.
- **The gate did not grow.** Five commands, unchanged: Swift 201, Python 95,
  both iOS builds, drift green. `unittest discover` finds `test_span.py`
  without a new command, job or README count.
- **Not measured yet.** Every span number. The ratios quoted above are the
  planted fixtures' and describe the *code*, not any capture: they are
  synthetic by construction, which is what lets them be printed here at all.

## 2026-08-14 · v0.10 — the estimand catches up with the code

**Amended inside the registration window, and the date is the point.** Commit 7
replaced the pooled null with a per-cell matched one and did not amend the
registered sentence, so `ESTIMAND` went on describing a design that no longer
ran. A registered criterion that disagrees with the code it names is worse than
an unregistered one: it reads as a promise kept.

- **What changed. The null is no longer separation-free.** The registered text
  said "partners matched on class and fine depth but drawn from a frame pair
  sharing no frame" and said nothing about how a null draw acquires a band; the
  plan behind it said more, and said the opposite of what now runs — "the null
  is flat in separation, and the same-pair curve rising toward a flat null IS
  the signal". It is not flat. Each null draw rides beside the same-pair draw
  it answers and inherits that draw's separation band, so numerator and
  denominator share a depth composition by construction and the comparison is
  within-cell.
- **Why this is still pre-registration, stated so a later reader need not
  guess.** The error was found on a **planted synthetic population**, before
  the threshold commit and **before any container was exported**. Amending
  criteria on synthetic data inside the registration window is legitimate — it
  is what the window is for. The same amendment after an export would not be,
  and would be indistinguishable in the artifact from this one if the
  distinction were not written down. It is written down here, dated, and the
  export has still not run.
- **What a cancellation looks like now, because the old sentence told a reader
  what to expect.** "A curve rising toward a flat null" belonged to the pooled
  design and would now mislead. The comparison is within each cell, so every
  separation dependence lives in the numerator and the ratio carries it
  directly: cancellation is a ratio **below 1 inside a band**, and cancellation
  degrading with distance is that ratio **rising toward 1 as the bands widen**.
  One in every band is independence; above one is anti-correlation, which is
  worse than the naive rule rather than the same as no effect.
- **The gap the amendment exposed: nothing compared an estimand's text to the
  code computing it.** That is now pinned structurally rather than lexically, on
  the two properties the sentence claims — a cell can never hold more null
  draws than same-pair draws, and every null separation is one a same-pair draw
  had. Reverting to the pooled null turns seven tests red including that one;
  before this commit it would have turned none of them red for the *reason*
  that matters, because no test named the relationship.
- **The gate did not grow.** Five commands, unchanged: Swift 201, Python 96,
  both iOS builds, drift green.
- **Not measured yet.** Every span number, all three registered values, and the
  export's size. No container has been exported.

## 2026-08-14 · v0.10 commit 8 — the lateral, and the floor its filter puts under it

**Built and gated, and the criterion gained the one constraint that is
derivable.** The lateral estimand is the forward-backward round-trip
displacement in depth pixels — the quantity the chain computes, compares
against `forwardBackwardRadius`, and throws away. It is reportable only beside
that radius, because the radius is what shaped it.

- **A test written to fail did, and the reason is the finding.** It asserted
  that a totally censored population would show a clearance near zero. It shows
  **0.28**. If the true displacement scale is far outside the radius, the
  survivors are the ones that happened to land inside it — uniform over the
  disk in the limit — and for points uniform on a disk of radius R,
  `P(r <= t) = t²/R²`, so the median radius is `R/√2` and the clearance
  `(R − median)/R` is `1 − 1/√2 ≈ 0.293`. **Clearance does not go to zero when
  the bound does all the work; it bottoms out.**
- **So the floor is registered, and it is derived rather than chosen.** A
  margin at or below `1 − 1/√2` would call a fully filter-shaped distribution
  reportable, which is the exact overclaim the criterion exists to prevent.
  `_registered_clearance` refuses such a value — the *constant* is rejected,
  not the data — and a test pins that both `0.10` and the floor itself raise.
  This turns `TODO(owner):` from "pick a number" into "pick a number above
  0.2929", which is a materially different request and the first of the three
  registered values to acquire a real constraint.
- **`atBound` rides beside the median for the same reason the radius does.**
  The share of survivors in the last tenth of the radius separates the two
  cases far more sharply than the clearance does — under 0.01 when the filter
  removed almost nothing, over 0.10 when it did the work. It is reported as a
  diagnostic and is not the criterion, because the criterion was registered
  before this commit and changing which statistic decides after seeing how the
  statistics behave is the move this rung exists to refuse. It is written down
  here so a later rung can register it deliberately if it wants to.
- **The fixture applies the filter rather than describing it.** Displacements
  are drawn and rejected until they fall inside the radius, exactly as the
  analysis only ever sees survivors. A fixture that planted the post-filter
  distribution directly would have assumed the very shape under test.
- **"Refused" is not "unavailable", the v0.6 reading.** The lateral number
  exists in both outcomes. What refusal means is that it is not reported,
  because what it measures is the filter and not the sensor — and the ROADMAP
  keeps its narrower entry, that the lateral component has never been measured.
- **The gate did not grow.** Five commands, unchanged: Swift 201, Python 101,
  both iOS builds, drift green.
- **Not measured yet.** Every span number, all three registered values, the
  export's size. The clearances quoted above are the planted fixtures' and
  describe the code; no container has been exported.

## 2026-08-14 · v0.10 commit 9 — the artifact, and the refusal it carries at the top

**Built and gated; `skewline-span/1` exists and has never been written from a
container.** Aggregates, verdicts and counts, mirroring `skewline-fit/1`'s
shape: the estimand at the top with fixed wording, the units, the derived rule,
and the schema checked before any field is believed.

- **`spanInterval: "refused"` is load-bearing, not decoration.** It sits at the
  top level so a reader who finds a ratio below 1 cannot take it as permission
  to print `1.42 m ± 0.03`, and `spanIntervalReason` says why in the artifact
  rather than only in this file: the estimand is an upper median of absolute
  *disagreement* rather than a sigma, so no coverage is defined against it; the
  component is axial, so it is not a distance; and no API here takes two
  points. A later reader meeting the JSON without the prose still meets the
  refusal.
- **The rule travels with the number.** `propagationRule` carries
  `Var(r_b − r_a) = Var(r_a) + Var(r_b) − 2·Cov(r_a, r_b)` and says in the same
  breath that it is axial only. v0.6 put its estimand in the artifact so no
  later rung could invent what the number meant; the same argument applies
  harder here, because a ratio is easier to misread than a length.
- **The privacy decision is now enforced by a test rather than by care.** The
  artifact carries no frame index, no pixel, no depth, no Δt and no residual —
  **and no minimum, maximum or illustrative example, because an extremum is a
  row**. The test serializes the artifact, scrapes every number out of the
  text, and requires no per-row `delta`, `depth`, `rt_dx` or `rt_dy` value to
  appear; it also requires none of the geometry column *names* to be mentioned.
- **Shown red by the mistake a helpful future edit would actually make.**
  Adding a `worstResidual` field — an illustrative worst case, the most natural
  thing in the world to want in a summary — turned the test red on the `delta`
  column. That is the failure mode the rule exists for: nobody would commit a
  row on purpose, and an extremum does not look like a row until it is named as
  one.
- **The lateral floor rides in the artifact too.** `lateralClearanceFloor`
  carries `1 − 1/√2`, so the constraint on the margin is legible from the file
  and not only from this entry.
- **The gate did not grow.** Five commands, unchanged: Swift 201, Python 104,
  both iOS builds, drift green.
- **Not measured yet.** Everything the artifact is shaped to hold. No container
  has been exported, all three registered values are open, and
  `Fit/span.json` does not exist.

## 2026-08-14 · v0.10 commit 10 — the pre-registration closes

**The three registered values, chosen and written down before any container
was exported.** That ordering is the registration. Nothing here is measured;
these are decisions.

- **`cancellationMargin = 0.10`.** A fixed margin chosen comfortably above the
  observed fixture noise floor of roughly ±0.03 — about three times it. The
  verdict boundary is therefore `ratio < 0.90`. The ±0.03 is a spread of
  planted-fixture readings and nothing more: this module refuses standard
  errors, p-values and confidence intervals, because observations are
  correlated across neighbouring pixels and frames and a pair is built from two
  samples correlated with each other by hypothesis. No interval is to be read
  off that figure.
- **`lateralClearanceMargin = 0.50`.** Above the analytically derived fully
  censored floor of `1 − 1/√2 ≈ 0.2929`, which the code enforces by refusing a
  smaller constant outright. In pixels, against the registered radius of 1.0:
  the round-trip median must sit below 0.50, where a fully censored population
  reads 0.7071.
- **`P = 8`, unchanged, and this is a decision rather than an edit.** No
  independent evidence exists to move it. **File size at the registered stride
  is not measured**: the commit-4 smoke export was deleted and left no figure,
  so there is nothing to weigh against, and moving the stride on an
  unmeasured worry would be exactly the unregistered adjustment the ordering
  forbids. `CalibrationProbe.swift` is not touched by this commit.
- **All three were filled before the first export command was typed.** A
  criterion with an open threshold is not registered, and the hole is where the
  data would otherwise walk in. The gate for the fill is the export, not the
  commit, and the export has still not run.
- **A predicted red, and the tests were rewritten rather than deleted.** Two
  tests asserted that the verdict functions raise while the thresholds were
  open; with the globals filled they had to fail, and they did. The unfilled
  behaviour is still worth pinning, so both now pass `None` explicitly into
  `_registered` and `_registered_clearance` instead of reading the module
  globals — they pin what an unset threshold *does* rather than observing that
  one is unset. Shown red against the filled constants by letting an unset
  value fall back to the global instead of refusing, which is the plausible
  edit and would have made an unregistered threshold answer quietly. Three
  further tests arrived with them: the two values are what was registered, the
  cancellation boundary is `0.90` across all five verdicts, and the registered
  clearance decides both lateral fixtures.
- **The gate did not grow.** Five commands, unchanged: Swift 201, Python 107,
  both iOS builds, drift green.
- **Not measured yet.** Every span number, and the export's size at the
  registered stride. No container has been exported.

## 2026-08-14 · v0.10 commit 11 — refuse a comparison the null cannot sharpen

**The second registered-but-unimplemented sentence this rung has caught
before export.** Commit 1 registered reading (b) of the sharpness condition
(`:2614-2623`): the margin is fixed in advance, and the null's own replicate
spread is checked afterward as a validity condition that "can only add
refusals and never manufacture an adoption, which is why it is the one
written down." Nothing computed that spread until now. (The first such gap
was the null's per-cell depth-matched binning, corrected at commit 7.)

- **Replicate means seed, not container.** `SEED` and `SEED_STABILITY_SEEDS`
  are this repository's only randomness on a measured path, and re-drawing
  the seed genuinely re-measures the same population — a replicate. A
  different container is a different scene, not a replicate of this one, and
  the four containers already have their own guard: unanimity. Reading
  "replicate" as container would spend that axis twice and leave
  `PAIRS_PER_CELL`'s own sampling noise — the thing actually varying between
  runs of this analysis on one file — unchecked. It would also compare the
  margin to a quantity it was never sized against: `CANCELLATION_MARGIN`'s
  own justification (commit 10) sizes `0.10` against a spread of
  planted-fixture *readings*, the same kind of quantity a seed re-draw
  produces, not a cross-scene spread.
- **New plumbing, not composition.** `seed_stability` (`:518`) already
  existed and returns *ratios* per seed. This adds `sharpness_spread`, which
  recomputes `cell_ratios` at each registered seed and reads `permuted`
  instead — the null's denominator, not the ratio — a genuinely new surface
  rather than something this commit merely wires together.
- **`None` propagates instead of corrupting a mean.** `cell_ratios` sets
  `permuted` to `None` below `MINIMUM_CELL_PAIRS`. If any of the three seed
  replicates for a band is `None`, or the mean of the three is zero,
  `sharpness_spread` reports `None` for that band rather than computing a
  spread over a value that was never really there, and `sharpness_verdict`
  reads a `None` spread as `INSUFFICIENT_PAIRS` — the same vocabulary
  `cell_verdict` already uses for a thin cell, not a new silence.
- **The spread's form is a specification, not a derivation, made before any
  container was exported.** `(max - min) / mean` across the three seeds'
  `permuted` values — the strictest of the candidates considered, because a
  stricter sharpness condition can only add refusals, never let one through.
  Alternatives considered and not chosen: `max/min - 1`, and
  `(max - min) / median`. The margin is routed through
  `_registered(margin, "CANCELLATION_MARGIN")` exactly as `cell_verdict`
  does, so an unset threshold still refuses to answer rather than falling
  back silently.
- **The granularity is an amendment, and it is MORE PERMISSIVE than the
  registered text, not stricter.** DEVLOG `:2621-2622` registers a
  class-scoped consequence: "the class is refused wherever the ratio fell" —
  every band of a class refused the moment any one band's sharpness fails.
  This implements cell (class × band) scope instead: only the failing band
  is refused, and the rest keep their own verdicts, including
  `CANCELS_WITH_MARGIN`. The cell-scoped refusal set is a strict subset of
  the class-scoped one, so this is a correction that lets through some
  adoptions the registered text would have refused — moving *against* the
  direction (`:2622-2623`) the registered reading justified itself by, which
  is why it is written down as an amendment rather than presented as though
  the class-scoped sentence had simply been carried out. The argument for
  making it anyway: the null's replicate spread is a property of one cell's
  own draw count and depth composition, so refusing a well-populated,
  sharply-measured band because a sparse band elsewhere in the same class
  wobbled would discard a valid reading for a reason unrelated to it. (That
  the ratio itself is already "reported per class and separation band and
  never pooled to one number" (`:110-111`) supports *computing* the
  condition per cell; it says nothing about the refusal's granularity and is
  not, by itself, the argument for the narrower scope.)
- **Measured on fixtures, not assumed.** With `PAIRS_PER_CELL = 20_000` the
  upper median is pinned tightly, so the guard's practical reach was worth
  checking before trusting it exists. On a planted fixture with thousands of
  pairs per band (20 disjoint frame pairs, 4,000 rows each, one fixed seed),
  the measured spread ran from about 0.004 to 0.015 across the
  well-populated bands — between roughly seven and twenty-five times below
  the `0.10` margin, and never close to it. At a moderately populated size
  (10 pairs, 1,000 rows each) spreads still stayed under 0.04. Near
  `MINIMUM_CELL_PAIRS`, bands
  read `None` (thin, not spread-refused) rather than a large spread. On this
  data the honest name for what `SHARPNESS_REFUSED` will actually catch is
  closer to a guard against anomalous seed-to-seed instability than a
  condition expected to fire on an ordinary well-sampled export — the
  thin-cell case is already caught by `INSUFFICIENT_PAIRS` before this guard
  is reached. `test_well_populated_cells_clear_the_margin_on_this_fixture`
  pins the measured magnitude as a regression rather than letting it drift
  unnoticed.
- **Tests.** Four: the verdict boundary at the registered margin including
  its edge; a thin fixture reading `INSUFFICIENT_PAIRS` rather than raising;
  `sharpness_spread` checked against a hand-computed value built from
  `cell_ratios`' own `permuted` field at each seed, to keep it visibly
  distinct from `seed_stability`'s ratio-based diagnostic; and the measured
  well-populated magnitude above. Python: 107 → 111.
- **The gate.** `.venv/bin/python -m unittest discover -s Fit -v` is green
  at 111. The full five-command gate, including both iOS builds, is run
  once and reported after commit 13, since nothing in commits 11-13 touches
  anything outside `Fit/`.
- **Not measured yet.** Every span number. No container has been exported.

## 2026-08-14 · v0.10 commit 12 — refuse a session with no disjoint pair

**The third registered-but-unimplemented sentence this rung has caught
before export.** The module docstring requires the null's partner come "from
a frame pair sharing no frame" (`:25-28`). A file with no such pair anywhere
has an undefined estimand — not a thin cell, the case `INSUFFICIENT_PAIRS`
already covers correctly. Commit 7's own words for it: a session that never
revisits a distance "has no null and no answer."

- **The rule, kept linear.** `has_disjoint_pair` uses `_pair_key` for
  identity rather than a quadratic pairwise scan (a long session has
  thousands of frame pairs). Two frame pairs are disjoint iff they share no
  frame, and a family of two-element sets that pairwise intersect is always
  either a star (one frame common to every pair) or a triangle (exactly
  three distinct pairs spanning exactly three frames — the only simple graph
  on three vertices with three edges). So: no disjoint pair exists iff fewer
  than two distinct pairs, or one frame is common to all of them, or there
  are exactly three distinct pairs over exactly three frames. Linear in the
  number of distinct pairs.
- **Placed in `cell_ratios`, not `read_geometry` — a placement correction
  found while writing the tests.** The plan called for a file-level check
  right after `read_geometry`'s existing three checks. Putting it there
  broke six passing tests: `TheLateralIsCensoredByItsOwnFilter`'s fixtures
  use one frame pair throughout, because the lateral estimand needs no
  partner pair at all, and `test_the_null_rejects_a_partner_that_merely_
  shares_one_frame` deliberately builds a file with only two frame pairs
  that share a frame, to exercise `permuted_samples`' own shared-frame
  rejection — a function the module docstring already marks as kept
  specifically for that refusal test, not the statistic's own path. Gating
  `read_geometry` would have made that file unreadable by anything,
  including the test built to read it. The check now lives at the top of
  `cell_ratios`, the null's own entry point, so `read_geometry` and
  `lateral_summary` are untouched and `permuted_samples` keeps a file it was
  built to exercise. This still satisfies "before any per-class work" — it
  is the first thing `cell_ratios` does, before `same_pair_samples` runs.
- **File-level, not class-level — write the gap down.** `has_disjoint_pair`
  ignores `class_index` entirely. `same_pair_samples` still selects by
  class, so a file that clears this check can still hold one class whose
  own rows all come from a single frame pair. Per-cell `INSUFFICIENT_PAIRS`
  remains the only guard at that finer granularity; this check does not
  widen to cover it.
- **`P` is not leaned on.** `P = 8` at `k = 1` makes kept pairs disjoint in
  practice, but the guard checks the actual condition rather than trusting
  another constant to make it true.
- **Tests.** Three: a star (four pairs sharing frame 0) and a triangle
  ({0,1}, {1,2}, {0,2}) both refuse with a message naming "no frame" and not
  "insufficient"; two pairs sharing no frame at all proceeds through
  `cell_ratios` without raising. Python: 111 → 114.
- **The gate.** `.venv/bin/python -m unittest discover -s Fit -v` is green
  at 114. Full gate reported after commit 13, as before.
- **Not measured yet.** Every span number. No container has been exported.

## 2026-08-14 · v0.10 commit 13 — give the span statistic a command line

**`span.py` can be run.** `fit.py` and `serve.py` have had `main(argv)` since
v0.6 and v0.7; `span.py` did not, and `build_artifact`/`write_artifact` had
no caller anywhere in the tree. Two gaps found while writing this commit
needed small new code first, not composition of what already existed:

- **Provenance had no producer.** `build_artifact` consumes a `provenance`
  list but nothing built its entries. `_provenance_entry` mirrors
  `fit.load_class_containers` exactly: `session` and `decimation`, nothing
  else — no path, no basename, since a basename can name a room and this
  entry is what ends up inside a committed file.
- **The radius comes from the file's own header, never a constant.**
  `_forward_backward_radius` reads `forward-backward-radius` out of the `/2`
  header's metadata and raises if it is absent, rather than assuming the
  `1.0` this rung has used in prose so far. A hardcoded fallback would have
  been silently wrong the day a container was exported at a different
  radius.
- **One artifact per container, never pooled.** `skewline-span/1`'s only
  axis is confidence class — `low`/`medium`/`high` — and it has no container
  axis. Writing one artifact per input file, each with a single-session
  `measuredOn`, keeps the four numbers the module docstring calls "the only
  guard" (unanimity across containers) visible across the separate files
  where they belong, rather than pooling them into one artifact where they
  would simply not exist. `ARTIFACT_SCHEMA` is untouched — it is registered
  and was already pushed at `d9e7207`.
- **Artifact filenames are session ids, never input basenames.** The
  provenance rule already keeps a basename out of the export's *contents*
  for privacy; putting it in the committed artifact's *filename* instead
  would leak the identical information one level up. `--output-dir <dir>`
  plus `<session>.span.json` per input file.

**A placement correction found while testing, not while planning.** Commit
12's disjoint-pair check lives in `cell_ratios`, not `read_geometry` — see
that entry — so nothing here had to route around it; `_analyze_container`
simply calls the functions in order and lets whichever raises first stop the
run.

**Two kinds of refusal, not one.** File-level `ValueError`s — the `/1`-file
check, the sampling-header check, commit 12's disjoint-pair check, the
missing-radius-header check above, and `camera_xy`'s per-row missing-
intrinsics check — are structural: the CLI exits non-zero (`1`) with the
underlying message, or `64` on a bad invocation (no `--output-dir`, no input
files — the same convention `fit.py` and `serve.py` use). Per-cell and
per-lateral verdicts — `INSUFFICIENT_PAIRS`, `LATERAL_REFUSED`, commit 11's
sharpness refusal — are not errors: `cell_verdict` and `lateral_verdict`
already return them as ordinary outcomes on real data, and conflating the
two would mean one sparse band in an otherwise healthy session fails the
whole run — discoverable only against a real export, which is the worst
possible moment to learn it. The report prints them and the process exits
`0`.

**The report is the registered list, not a better-looking one.** Per class
and per separation band: every input container's ratio printed separately,
never pooled — a pooled mean would hide a squeaker; unanimity against
`ratio < 0.90` (`cell_verdict == CANCELS_WITH_MARGIN` in every container);
a ratio above `1` (`ANTI_CORRELATED`) called out as its own finding, never
folded into "does not cancel"; commit 11's sharpness verdict per container,
which refuses regardless of where the ratio fell; the lateral round-trip
median against the `0.50` px margin beside its truncation bound and the
fraction of survivors at the bound; seed stability across the three
registered seeds; and each written artifact's `spanInterval: "refused"`
field, unchanged and only surfaced, not recomputed.

**Two things decided now, not left open.** The unanimity verdict lives only
in the printed report — correct, since it is a cross-file comparison and
the artifact schema has no container axis to hold it in — which means the
only place it is ever written down is whichever commit runs a real export
and records what it found; that commit owns capturing it, not this one.
Separately: `README:40` documents `serve.py`'s invocation but neither
`fit.py`'s nor `span.py`'s, and no drift assertion covers Python CLI
invocations, so the gate stays green either way — this commit does not add
a README line for the new CLI, since doing so would widen a `feat:` commit
about giving `span.py` an entry point into a documentation commit too. That
line is deferred to the v0.10 closing doc commits.

- **Tests.** Seven, on `TheCommandLine`: the four structural refusals, each
  checked for its own message; the missing-radius-header refusal, checked
  separately since it is new to this commit rather than one of the four the
  plan enumerated; a thin-cell fixture that reports `INSUFFICIENT_PAIRS`
  and still exits `0`; and two containers built with deliberately different
  cancellation strength, whose independently-computed ratios are asserted
  distinct and both required to appear verbatim in the printed report — the
  property a pooled driver could quietly lose. Python: 114 → 121.
- **The gate.** All five commands, run once for commits 11-13 together since
  nothing in them touches anything outside `Fit/`: `swift build && swift
  test` — Swift, unchanged at 201; both `xcodebuild` invocations green;
  `.venv/bin/python -m unittest discover -s Fit -v` — green at 121;
  `swift Scripts/readme-drift.swift` — green.
- **Not measured yet.** Every span number, and the export's size at the
  registered stride. No container has been exported.

## 2026-08-14 · v0.10 commit 14 — analyze all span containers before writing

**Independent review of commits 11-13 found one correctness bug and one
documentation error in `_analyze_container`/`main`, both fixed here, plus
one optimization taken while the same code was open.**

- **A mid-run refusal was leaving a partial artifact set on disk.** `main`
  wrote each container's artifact inside the same loop that analyzed it, so
  four containers with the third refusing left two artifacts written and
  exit `1` — and unanimity is read across all four files, so a partial set
  is precisely the state that invites a wrong reading of it. Every container
  is now analyzed first, in one loop, and only if all of them succeed does a
  second loop write any artifact.
- **`_analyze_container`'s own docstring cited the wrong functions for two
  of its five refusals.** It said the disjoint-pair check lives in
  `read_geometry`; it lives in `cell_ratios` (`has_disjoint_pair`'s own
  docstring already said so correctly, one function away). It said the
  missing-intrinsics-row check is inside `cell_ratios`; it is inside
  `camera_xy`, reached through `same_pair_samples`. Both corrected, and the
  "before any artifact is written" claim is now true across the whole run,
  not only per container, since the ordering fix above makes it so.
- **`cell_ratios` was called seven times per class where three suffice.**
  `results` called it once at `SEED`, `sharpness_spread` recomputed it at
  each of the three registered seeds, and `seed_stability` recomputed the
  SAME three seeds again — `SEED == SEED_STABILITY_SEEDS[0]`, so `results`
  duplicated one of the other two's calls exactly. `_cell_ratios_per_seed`
  now computes the three registered seeds once per class; `seed_stability`
  and `sharpness_spread` are thin wrappers over it for any caller that wants
  just one diagnostic, and `_analyze_container` reads `results`, `sharpness`
  and `stability` from the one shared computation. Deterministic before and
  after, so this is a performance change with no output difference — every
  test that pinned a specific numeric result still passed unchanged.
- **Not a fabricated measurement, but worth naming: no benchmark exists for
  the speedup.** The reviewer estimated roughly 2.3x the necessary work
  before this commit; that arithmetic is theirs, not a measured wall-clock
  figure, and none is claimed here.
- **The gate.** `.venv/bin/python -m unittest discover -s Fit -v` is green
  at 121, output unchanged from commit 13's run. The other four commands are
  unaffected — nothing outside `Fit/span.py` and `Fit/test_span.py` changed
  — and were not re-run.
- **Not measured yet.** Every span number. No container has been exported.

## 2026-08-14 · v0.10 commit 15 — correct the measured sharpness spread

**Commit 11's own record of a measured magnitude was itself imprecise, and
this rung's argument for stating magnitudes at all is that they be exact.**

- **"An order of magnitude below" overstated the top of its own range.**
  Commit 11 reported the sharpness spread on a well-populated fixture as
  running "from about 0.004 to 0.015 ... an order of magnitude below the
  `0.10` margin." `0.10 / 0.004` is 25 — an order of magnitude, at the low
  end. `0.10 / 0.015` is about 6.7 — not one, at the high end the same
  sentence claimed it for. Corrected to "between roughly seven and
  twenty-five times below the `0.10` margin," which is true across the
  whole stated range rather than only its most favorable point. The same
  overstatement was duplicated in `test_span.py`'s comment beside
  `test_well_populated_cells_clear_the_margin_on_this_fixture` (there
  compounded with a wider, unlabeled 0.003-0.04 range that mixed the
  well-populated and moderately-populated fixtures together); corrected to
  match, and to name which fixture the 0.004-0.015 figure belongs to.
- **No number changed, no test changed.** This is a wording correction only
  — the measured values (`0.004`, `0.015`, `0.10`) and the passing
  assertions are exactly as commit 11 left them. What was wrong was the
  arithmetic comparing them in prose, not the arithmetic in code.
- **The gate.** `.venv/bin/python -m unittest discover -s Fit -v` is green
  at 121, unchanged — a comment and two sentences of prose, no executable
  line touched. The other four commands are unaffected and were not re-run.
- **Not measured yet.** Every span number. No container has been exported.

## 2026-08-14 · v0.10 — the span measurement, and the one cell it does not settle

**Run, and recorded before anything closes.** Every entry in this rung so far
has ended by saying that every span number was unmeasured and that no container
had been exported. The export and the analysis were both run by hand at the
shell, and four `skewline-span/1` artifacts enter the repository with this
entry, one per container and named by session id. What follows is what they
hold — including the one cell they do not settle, and the figures in this entry
that nothing in the tree can check.

- **The shape the amendment predicted is the shape that arrived.** `:3050-3051`
  wrote, before any container was exported, that under the per-cell null
  "cancellation is a ratio **below 1 inside a band**, and cancellation degrading
  with distance is that ratio **rising toward 1 as the bands widen**." Across
  all twelve container-and-class series the ratio is monotone increasing over
  all seven separation bands, without exception — 84 cells, twelve series, no
  inversion anywhere. That is a description of what the numbers do and it is
  offered as nothing more: no p-value, no test, no interval. This module refuses
  those, and a monotone sequence is a description rather than a null rejected.
- **Cancellation is strong at short separations and weakens as the points
  part.** Band by band, the extremes across the twelve series: `[0.00,0.02)`
  0.077–0.187, `[0.02,0.05)` 0.128–0.326, `[0.05,0.10)` 0.171–0.465,
  `[0.10,0.20)` 0.213–0.622, `[0.20,0.40)` 0.308–0.816, `[0.40,0.80)`
  0.484–0.931, `[0.80,1.60)` 0.609–1.001. The cells themselves are in the four
  artifacts and are not repeated here. All of it is **axial**: `r` is planar z
  along the target camera's optical axis, so a ratio of 0.077 describes one
  diagonal element of a point's error and not a distance.
- **The unanimity verdict this entry owns, and it is not unanimous.** Commit 13
  (`:3407-3411`) left it here on purpose — the verdict is a cross-file
  comparison the artifact schema has no axis to hold, so "the only place it is
  ever written down is whichever commit runs a real export". Against
  `ratio < 0.90`, `CANCELS_WITH_MARGIN` in every container, unanimity holds in
  18 of the 21 class-and-band cells and fails in three, all at the widest
  separations: `medium` `[0.40,0.80)`, `medium` `[0.80,1.60)` and `high`
  `[0.80,1.60)`. Across the 84 cells the census is 77 `CANCELS_WITH_MARGIN`, 6
  `CANCELS_WITHOUT_MARGIN`, one `ANTI_CORRELATED`, and no `INSUFFICIENT_PAIRS`
  at all. The registered criterion answered; it did not answer yes everywhere,
  and the three cells where it did not are named rather than averaged away.
- **The one cell above 1 is a verdict the data does not settle, not an
  anti-correlation finding.** M1 `931A8965`, `medium`, `[0.80,1.60)`, ratio
  1.000625 — the only cell of 84 above one. At the three registered seeds that
  same cell reads 1.000625, 0.996067 and 1.001085, straddling the boundary the
  verdict turns on. Its distance to that boundary is 0.000625; the seed range is
  0.005018, eight times larger. Across all 84 cells and both registered
  boundaries — 0.90 and 1.00 — it is the only cell whose seed range contains
  one. The artifact is not wrong and `cell_verdict` is not unstable: at
  `SEED = 0` the ratio is above one and the verdict is deterministic. What moves
  is the verdict across the seeds, and a verdict the seed decides is not a
  reading. `:3052-3053` calls anti-correlation "worse than the naive rule rather
  than the same as no effect", which is exactly why this cell is reported as
  unsettled instead: a finding that severe cannot rest on a coin.
- **The registered sharpness condition did not catch it. The seed-stability
  diagnostic did.** Sharpness measures the null's own replicate spread against
  the `0.10` margin, and it cleared all 84 cells — no `SHARPNESS_REFUSED`
  anywhere. That is the condition doing what commit 11 said it would:
  `:3272-3274` predicted that "the honest name for what `SHARPNESS_REFUSED` will
  actually catch is closer to a guard against anomalous seed-to-seed instability
  than a condition expected to fire on an ordinary well-sampled export", and it
  did not fire. What caught the straddle is the other diagnostic, the one
  `span.py:163-171` exists for — "a statistic that moves with the seed is a
  finding". The two look alike and are not: sharpness asks whether the null's
  **denominator** is stable across replicates, seed stability asks whether the
  **verdict** is. Only the second can see a boundary, because only the second
  knows there is one. A cell can be sharply measured and still be undecided, and
  this cell is both.
- **The null held its disjointness.** `sharedFrameLeaked` is 0 in all twelve
  container-and-class blocks, and `sharedFrameRejected` runs 69,023 to 174,552 —
  the guard had work to do and never leaked, which is the non-vacuous form
  `span.py:365-368` demands of it rather than a zero on data where sharing never
  arose. `unmatchedPartners` is 0 in all twelve: every same-pair draw found a
  depth-matched partner inside `DEPTH_MATCH_TOLERANCE`. `targetPixelCollisions`
  runs 0 to 42 across the twelve, rejected rather than measured.
- **`pairsPerCell: 20000` counts draws per frame pair, not pairs per cell, and
  the field is not renamed.** `span.py:342` sits inside the
  `for key in np.unique(keys)` loop, so the cap is per `(source, target)` frame
  pair and the separation bands are assigned afterwards. The cells actually hold
  5,003 to 703,315 pairs, none of them below `MINIMUM_CELL_PAIRS = 2,000`. A
  reader meeting `pairsPerCell: 20000` beside a cell of 703,315 has met two
  numbers that contradict each other, and the fix is this sentence rather than
  the schema: `ARTIFACT_SCHEMA` is registered and was pushed at `d9e7207`, and
  renaming a field after the export so that a reading comes out right is
  precisely the edit a registration exists to forbid. The name stays; the
  reading is corrected here, beside the number.
- **The lateral is a reading of the sensor, not of the filter.** Round-trip
  medians run 0.3884 to 0.4233 depth pixels against a truncation radius of 1.0,
  read from each file's own header and never assumed. Clearance runs 0.5767 to
  0.6116 against the registered `0.50` margin, far above the 0.29289 floor a
  fully censored population would still show. `atBound` — the share of survivors
  in the last tenth of the radius — is at most 0.019850. All twelve are
  `LATERAL_REPORTABLE`: the bound is not binding at the statistic, so what these
  numbers describe is the sensor.
- **Export stats, per container, one release run each.** `--separations 1
  --pair-stride 8`, timing as printed and never averaged:

      M1 931A8965: 32,268,881 survivors, 4,041,636 rows kept, 109 of 865
        pairs, 109 frames, 371,516,691 bytes, analysis 36.28 s
      M2 1A68AF96: 29,991,724 survivors, 3,798,210 rows kept, 106 of 846
        pairs, 106 frames, 349,652,604 bytes, analysis 33.42 s
      D1 85E5E2F1: 29,827,060 survivors, 3,729,627 rows kept, 108 of 863
        pairs, 108 frames, 342,893,661 bytes, analysis 42.79 s
      README 2110CDA9: 31,200,020 survivors, 3,922,010 rows kept, 111 of 882
        pairs, 111 frames, 361,116,997 bytes, analysis 45.41 s

  One run each, not the two `:1176` reported, so its "X s then Y s" shape is not
  borrowed. Two containers were first started under a debug build and
  interrupted before completing; every figure above is from the release run that
  replaced it, said here rather than left implying four clean first attempts.
  **No comparison with v0.6's timings is made.** These ran with `--separations
  1` and wrote about 4M rows to disk that v0.6's runs did not, so the two are
  quantities with different work inside them. The flags are stated and the
  comparison is left unmade.
- **The whole filter cascade reproduced, seventeen commits later.** All four
  survivor totals above reproduce v0.6's record at `:1177-1182` exactly, and the
  `[1,2)`-band `k=1` high-class counts reproduce `:1163-1168` exactly. That
  earlier consistency check was one band of one container; this is the whole
  cascade producing an identical survivor set, from a release build seventeen
  commits on. Rows kept differ, as they must: M1's 504,208 at every-Nth 64
  became 4,041,636 at pair-stride 8, a factor of 8.016.
- **The privacy argument, as arithmetic.** 37,748 bytes of artifact enter the
  repository. The four `/2` files they were derived from total 1,425,179,953
  bytes and stay outside it, beside the containers, where commit 1 put them.
  Those two numbers next to each other are the confinement rule stated as a
  ratio rather than as a principle.
- **What the artifacts hold, what only this entry holds, and what nothing can
  check.** `build_artifact` writes cells, counters and the lateral summary. It
  writes no verdict, no seed stability and no sharpness spread — `_print_report`
  prints those and the run ends. So the unanimity verdict, the sharpness
  clearance and the three seed ratios above exist in this entry and nowhere else
  in the tree. Stated plainly rather than left to be discovered: **the seed
  ratios and the sharpness verdicts are single-sourced from the run that
  produced them.** The outside review's arithmetic was performed on the CLI's
  printed report, not on the artifacts, and no second execution exists. Nothing
  committed here can be used to check them, and the only route to a second
  opinion is another run against the `/2` files — which stay on one machine by
  the privacy rule this rung chose. That is a cost of the confinement rather
  than an oversight, and naming it is cheaper than implying a verification that
  did not happen. v0.6's reproducibility gap, inherited and widened, exactly as
  commit 1 said it would be.
- **One commit for the artifacts, the entry and the ROADMAP clause — and no gate
  would have caught the alternative.** `:1954-1961` gives the rule: split when
  each half is independently green, combine when splitting would commit a defect
  on purpose. Artifacts-plus-entry alone would leave the tree holding four
  `skewline-span/1` files beside a ROADMAP sentence reading "the correlation
  still has not been measured, and that clause stands here until a number
  replaces it" — the number in the tree and the clause false, for the length of
  one commit. So they land together. The difference worth recording is that
  there, `readme-drift.swift:157` and `:165` would have gone red on the split;
  here the check never reads *Deliberately not built* at all, so nothing would
  have caught it. The same rule, held without the tool that enforced it last
  time. The customary `docs: move v0.10 into the roadmap's shipped list` stays a
  separate commit after the README close: the precedent is deferred, not
  abandoned.
- **The gate.** All five commands, run on this change: `swift build && swift
  test` — Swift, unchanged at 201; both `xcodebuild` invocations green;
  `.venv/bin/python -m unittest discover -s Fit -v` — green at 121;
  `swift Scripts/readme-drift.swift` — green. Nothing executable changed, so no
  count moved.
- **Not measured yet.** The line shrinks rather than disappears. The span
  numbers are measured, and the export's size at the registered stride — open
  since `:2908` and still open at `:3196` — is answered above. Still not
  measured: `span.py`'s own runtime, which was never timed and for which nothing
  was recorded, and peak memory for either the export or the analysis. v0.8's
  latency trigger is untouched and stands on its remaining half.

## 2026-08-14 · v0.10 — the close, and the first time the ladder ends

**One commit, and this time the gate decided it rather than the author.** The
close moves the README ladder's last rung to `done` and moves the ROADMAP row
out of *What is next* into *What has shipped*. Both files, together, because
`Scripts/readme-drift.swift` refuses either half on its own — checked by reading
it rather than by assuming the shape the last three closes used.

- **Both halves are red alone, so `:1954-1961`'s rule gives one commit.** The
  README edit alone makes `ladderHasEnded` true at `:166` while the ROADMAP
  still carries its `| **v0.10** span |` row, and the row loop at `:210` fails
  that row at `:221-226` — "the ROADMAP still lists v0.10 in its what-is-next
  table". The ROADMAP edit alone empties `roadmapRows` while the ladder still
  marks a rung current, and that fails at `:202-204`. Neither half is
  independently green, so splitting would commit a red gate on purpose. Note
  that these are **not** the `:157`/`:165` citations the v0.8-to-v0.9 boundary
  recorded at `:1954-1961`: the file has moved since, and those lines are now
  `doneRows` and the `ladderHasEnded` comment. The failures are at `:204` and
  `:221-226`, cited from this reading rather than carried forward.
- **The trap is `:197-207`, and the empty table stays.** With the ladder ended
  and no rows left, the assertion requires the literal
  `| Version | Ships | What forces it |` to still be present: deleting the
  now-empty section fails at `:206`, because "an empty table is a state where a
  missing one is drift". The row moved out; the header stands, with the
  separator row beneath it and nothing after. A section that looks unfinished is
  the intended appearance of a finished ladder.
- **Three paths in the drift gate execute for the first time in this
  repository's history.** No ladder here has ever ended, so `ladderHasEnded`
  has been false at `:166` on every previous run; the `:172` branch that
  permits no current rung has never been taken; and the `:205-207` empty-table
  branch has never been reached, because `roadmapRows` has never been empty
  while the ladder was done. All three run green on this commit — and green
  alone would not have been evidence, because code that never runs and code
  that runs correctly are indistinguishable from a passing gate. **Both
  refusals were shown red first.** Deleting the table header produced `:206`'s
  message verbatim — "an empty table is a state where a missing one is drift" —
  and exit `1`; putting a `| **v0.10** span |` row back while the ladder stayed
  `done` produced `:221-226`'s — "the ROADMAP still lists v0.10 in its
  what-is-next table" — and exit `1`. Both edits were reverted and the gate is
  green on the committed state. The `:172` branch is the exception and cannot
  be shown red: it is an empty branch whose whole content is permitting the
  state, so only its absence would be visible. These assertions were written at
  v0.8's close against a state that did not exist yet; they were speculative
  for two rungs and are load-bearing for the first time today.
- **Four steps, not fifteen.** v0.10 landed fifteen commits and three
  non-commit entries; *What has shipped* gains steps 36 to 39, at the
  granularity the list already uses — v0.6 and v0.7 took two apiece, v0.9 took
  six. The seam and its confinement; the statistic and its per-cell null; the
  thresholds registered before the data and the refusals they buy; and what the
  measurement found. "Thirty-five steps" became "Thirty-nine steps", which no
  assertion checks and which is therefore exactly the kind of number that rots.
- **What the close does not do.** It does not touch the *Deliberately not
  built* span entry, which the measurement commit already amended and which
  still refuses. Step 39 says so in its own last sentence: the trigger was met
  and the refusal survived it, because what was measured is a ratio of upper
  medians and not `Cov(r_a, r_b)`. A rung closing is not a licence to revisit a
  refusal that closed on its own terms.
- **The divider goes, and the condition on its return is not reinterpreted.**
  It returns with the next rung, if a next rung is forced — the same sentence
  v0.9's close left. What changed is that no rung is queued to force one, and
  the honest way to write that is as a state rather than as either a promise of
  more or a declaration of done.
- **The gate.** All five commands, and `readme-drift` is load-bearing here in a
  way it was not for the last three commits: `swift build && swift test` —
  Swift, unchanged at 201; both `xcodebuild` invocations green;
  `.venv/bin/python -m unittest discover -s Fit -v` — green at 121;
  `swift Scripts/readme-drift.swift` — green, exercising the three
  first-time paths above.
- **Not measured yet.** Unchanged from the measurement entry: `span.py`'s own
  runtime and peak memory for either the export or the analysis. v0.8's latency
  trigger is untouched and stands on its remaining half, and an ended ladder
  does not trip it.

## 2026-08-14 · v0.10 — the figure, and the only guard an image can have

**A picture of a measurement is a claim, and this repository has no way to
review one.** Every other number here is either in a diff or under a test. An
SVG is neither: it is 13 KB of coordinates nobody reads, sitting beside prose
that says what it shows. `Fit/span_figure.py` draws the span result from the
four committed artifacts, and `Fit/test_span_figure.py` is what makes the
drawing checkable at all.

- **The generator computes nothing.** Every value it draws is already in an
  artifact, put there by `span.py`. A figure that recomputed a median would be
  a second implementation of the estimand with no test holding it to the
  first, and the failure mode is a picture that disagrees with the artifact
  beside it while both look right. It reads `ratio`, `separationEdges` and
  `measuredOn`, and it does arithmetic no more interesting than scaling a
  number to a pixel.
- **Byte-determinism, and the test that spends it.** Inputs sorted by session
  rather than taken in `os.listdir` order, since the filesystem's ordering is
  not a property of the measurement; one float-formatting rule for every
  coordinate, so `12`, `12.0` and `12.00` cannot appear in three runs for the
  same quantity; no timestamp anywhere. The test regenerates both files and
  asserts equality with what is committed. **Shown red first**: changing one
  colour in `docs/media/span-light.svg` by hand turned two tests red with the
  exact diff quoted, and regenerating turned them green. That is the whole
  argument for the module — an image cannot be reviewed, so it is instead made
  reproducible and pinned.
- **Standard library only, and `requirements.txt` is not touched.** The
  analysis needs `numpy`; scaling a number to a pixel does not. A figure is
  not a reason to widen the environment the gate runs in, and a dependency
  added for a nicety is one the four other Python files inherit forever. The
  cost paid for that: `ARTIFACT_SCHEMA` is duplicated rather than imported from
  `span.py`, because importing it would drag `numpy` into a module whose whole
  claim is that it needs nothing. The duplication is pinned by a test asserting
  the two constants equal, which is this repository's habit for a relationship
  it will not encode in an import.
- **Colour carries the class, and the steps were checked rather than chosen.**
  Twelve lines, three colours: the four containers inside a class are
  replicates of each other rather than four identities, so they share its
  colour, and what distinguishes them is that there are four lines. The three
  steps clear a lightness band, a chroma floor, adjacent-pair separation under
  simulated deuteranopia and tritanopia, a normal-vision floor, and 3:1
  contrast against that mode's own surface. The repository's own
  `ConfidencePalette` was the starting point and **did not pass as-is**: its
  amber sits at lightness 0.796 and reads 1.86:1 on a light surface, so the
  red and the amber were re-stepped. Worth recording that the palette's
  docstring already claimed the property that mattered most — separability
  under red-green colour-vision deficiency — and that claim held: the checked
  separation is well clear of the floor. What failed was contrast, which the
  docstring never claimed.
- **Dark is selected, not flipped.** The two modes carry different steps
  because the same colour cannot clear both surfaces: the light band tops out
  at 0.77 and the dark band at 0.67, so the amber that passes one fails the
  other. A test asserts the two palettes are not equal, so a later edit that
  "simplifies" them into one dictionary goes red rather than shipping a dark
  figure validated against a light surface.
- **Rendered and looked at, which caught what no check would have.** The first
  layout put the three direct labels past the right edge and ran the caption
  to the canvas boundary; both were invisible to every assertion in this
  repository and obvious in a screenshot. Widened gutter, shorter annotation,
  caption split across two lines. A palette validator checks colour, not
  geometry.
- **One finding is drawn rather than described, and it is found rather than
  hardcoded.** The single cell above 1 gets a ring and four words. The
  generator locates it by scanning for `ratio > 1.0` and annotates only when
  there is exactly one, so a future export with none, or with several, draws
  nothing instead of pointing at the wrong place.
- **The gate.** `.venv/bin/python -m unittest discover -s Fit -v` is green at
  **134**, up from 121. `swift Scripts/readme-drift.swift` is green: assertion
  1 walks the tree by first line, and an SVG begins `<svg`, so neither asset is
  mistaken for an observation export. The three other commands are unaffected —
  nothing outside `Fit/` and `docs/media/` changed — and were not re-run; the
  full five run on the README commit that follows.
- **Not measured yet.** Unchanged: `span.py`'s own runtime, and peak memory for
  either the export or the analysis. Nothing here was timed either, and the
  figure's own generation cost is not a number anybody asked for.

## 2026-08-14 · v0.10 — the figure reaches the readme

**The split the ladder close could not have, and the reason is the rule rather
than the custom.** `:1954-1961` splits when each half is independently green
and combines when splitting would commit a defect on purpose. Here both halves
are green alone: the generator, its test and the two assets landed at `334ad9e`
with `readme-drift` green and no README claim depending on them, and this
commit adds the README paragraph to files already in the tree. So the customary
pair is restored — unlike the close two commits ago, where each half was red
and one commit was forced.

- **`<picture>` rather than a filter.** Dark mode selects the file drawn for a
  dark surface; it does not invert the light one. A CSS filter would have been
  one line and would have produced colours nobody validated — inverting a
  palette moves every step off the band it was checked against, and the whole
  argument for the two files is that each mode's steps were checked separately.
  The `<img>` inside carries the light asset, so a reader whose client ignores
  `<source>` gets a working figure rather than nothing.
- **The alt text describes the shape, not the subject.** "A chart of the span
  result" tells a screen-reader user only that they are missing something.
  What is written instead is what a sighted reader takes from it: twelve curves
  rising from roughly 0.08 toward 1.00, four per class, all monotone, one
  crossing 1.00 and ringed. The caption beneath then carries the finding for
  every reader, which is where it belongs — a figure that needs its caption is
  normal, and a figure whose caption is its only honest part is not.
- **Two drift assertions were checked before writing, not after.** Assertion 3
  matches a bolded-and-backticked single word in the README and demands a
  matching `.library` product, so nothing in the new paragraph is written that
  way — `Fit/span_figure.py` appears in plain backticks. Assertion 4 counts
  "<number> CI jobs"; the README's existing sentence is untouched, since no job
  was added. Both were read out of `Scripts/readme-drift.swift` rather than
  recalled.
- **The claim the paragraph makes is the one the figure can support.** It says
  the errors cancel and that the cancellation weakens with separation; it says
  the one cell above 1 is a question rather than a finding; and it says plainly
  that this is still not an interval, because a ratio of upper medians against
  a permutation null is not a covariance. A README paragraph is where an
  overclaim would do the most damage, being the only page most readers see.
- **The gate.** All five commands, since the README changed:
  `swift build && swift test` — Swift, unchanged at 201; both `xcodebuild`
  invocations green; `.venv/bin/python -m unittest discover -s Fit -v` — green
  at 134; `swift Scripts/readme-drift.swift` — green.
- **Not measured yet.** Unchanged: `span.py`'s own runtime, and peak memory for
  either the export or the analysis.
