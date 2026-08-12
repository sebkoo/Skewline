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
