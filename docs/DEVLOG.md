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
