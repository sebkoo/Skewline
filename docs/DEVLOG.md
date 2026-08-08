# DEVLOG

Decisions and their reasons, written the day they were made. The commit log
says what changed; this says why, and what I was unsure about.

## 2026-08-08 — commit 1: the types that carry a pose and its uncertainty

Five files, one commit, no capture code. The whole point of starting here is
that the thing I want to test is a claim about data, not about ARKit: a spatial
result needs a confidence next to it, or it is a number nobody can act on.

**The pose and its covariance are fields of the same struct.** They could have
been two parallel arrays indexed together, which is how most capture formats do
it, and that is exactly the failure I want to make impossible — the moment they
are separable, some code path drops one and keeps the other, and the remaining
number looks authoritative. `PoseObservation` holds timestamp, transform,
covariance and tracking quality together or not at all.

**`Transform4x4` stores four `SIMD4<Float>` columns rather than a
`simd_float4x4`.** Apple ships no `Codable` conformance for the `simd` matrix
types, so deriving `Codable` on a struct holding one fails to synthesise. The
stdlib's `SIMD4<Float>` is `Codable`, `Equatable` and `Sendable`, so four
columns give me all three for free and no hand-written coder. `init(_
simd_float4x4)` and the `simd` computed property make the conversion lossless,
so nothing downstream has to care. I checked this by compiling it on the
toolchain in front of me (Swift 6.3.3) rather than trusting the documentation.

**Every public type declares `Sendable` explicitly.** SE-0302 withholds
implicit conformance from public types, and I expected that to cost nothing in
synchronous code — but it turned out to be load-bearing immediately, because
`Transform4x4.identity` and `PoseCovariance6x6.zero` are `public static let`,
and SE-0412 requires global constants to be `Sendable`. Without the explicit
conformance those two lines do not compile.

**`Core` does not import ARKit.** `TrackingQuality` and
`TrackingLimitedReason` mirror the shape of `ARCamera.TrackingState` without
depending on it. That keeps the ingest boundary as a separate decision for the
next commit, and it keeps the test target from dragging a device-only framework
into a suite that has to run on a laptop.

**The covariance layout is a guess and I want that on the record.** Flat 36
`Double`s, row-major, over `[x, y, z, roll, pitch, yaw]`, m² for the
translation block and rad² for the rotation block, with a `precondition` on the
count. It is the obvious first parameterisation and it may be the wrong one —
once there is an actual uncertainty model fitted to real sessions, quaternion
tangent space is the likely alternative, and switching means a migration. Also
worth noting that the pose is `Float` and the covariance is `Double`; that
asymmetry was not deliberate so much as each side taking its natural type, and
I have not decided whether it should stay.

**What the test does and does not check.** One test writes a session with a
non-identity transform, non-zero covariance and `.limited(.excessiveMotion)` to
a temp file, reads it back, and asserts the transform, covariance and tracking
quality are exactly equal. Exact equality is fair here because
`JSONEncoder`/`JSONDecoder` use shortest-round-trip float encoding, so any
tolerance would be hiding a codec bug rather than accommodating arithmetic. It
does not assert on `timestamp`, `id` or `startDate` — session-level metadata is
untested, which is a gap I am carrying into commit 2.

**What my own brief got wrong.** It said "no name in this commit", but
`Package.swift` requires a `name:` field, so the rule was unsatisfiable as
written. What I meant was "no brand" — the package is called `SpatialCapture`,
which is a description, and the targets stay `Core` and `Replay`. Renaming
later is still one line.

**I checked that the test can fail.** A test that passes in 0.016 s proves
nothing on its own, so I broke the codec on purpose: a temporary `encode(to:)`
on `PoseCovariance6x6` that writes 36 zeros regardless of the real values.
`swift test` went red at the covariance expectation, printing the decoded zeros
against the original `[0.0, 0.001, 0.002, …]`. Reverted. So the round-trip test
is genuinely checking that uncertainty survives storage, which is the one thing
this commit exists to establish.

**Tests run on the Mac, not on a device.** Running the test target in Xcode
against an iPhone destination fails outright — SwiftPM test targets are
tool-hosted and tool-hosted testing is unavailable on device destinations.
`swift test` in the terminal builds for `arm64e-apple-macos14.0` and works,
because `platforms: [.iOS(.v18)]` sets a minimum deployment target for iOS
rather than restricting which platforms can be built, and nothing in `Core` or
`Replay` touches an iOS-only framework. That is a consequence of keeping ARKit
out, not a coincidence. When CI arrives it should run `swift test` on a macOS
runner, and `platforms:` should probably name macOS explicitly so the manifest
states the intent instead of relying on the fallback.

## 2026-08-08 — commit 2: the boundary that makes the tests honest

Commit 1 claimed the pipeline was testable without hardware, but nothing tested
that claim because there was no hardware path to be independent of. This commit
adds the ingest boundary and a second way through it, so the claim is something
the compiler and the suite enforce rather than something I assert.

**`canImport(ARKit)` is true on macOS, and that cost me a build.** I gated the
live conformer with `#if canImport(ARKit)` expecting it to be false on this Mac.
It is not — a stub exists in the macOS SDK, so the import succeeds and then
`ARSession` and `ARCamera` are missing. The gate had to become
`#if canImport(ARKit) && os(iOS)`. I found this by letting the build fail, not
by reading anything. The general lesson worth keeping: `canImport` answers
"can this module be imported", not "are the symbols I want present on this
platform", and those are different questions on Apple platforms.

**The protocol went in `Capture`, not `Core`.** Putting it in `Core` would have
made every module depend on the ingest abstraction, and `Core` is supposed to be
data with no behaviour. In `Capture` it costs nothing: `Core` and `Replay` were
not touched at all, and the graph stays a chain — `Core` → `Replay` → `Capture`,
with `Capture` depending on both. `Replay` gained no dependency, so it cannot
cycle back. The one wart is that `Capture` needs `Replay` only for the
`CaptureSession` *type*; `CaptureSession` is arguably data and belongs in `Core`,
but moving it means reopening commit 1, so it stays where it is for now.

**Pull, not push.** `observations()` returns a concrete
`AsyncThrowingStream<PoseObservation, any Error>` rather than an associated
type, so the protocol stays existential-friendly and one non-generic consumer
works unchanged against every conformer. That was the actual constraint: if the
consumer has to know which source it holds, the boundary failed. The test proves
it by draining a real `ReplaySessionSource` and a trivial test-only fake through
the same helper.

**`.zero` covariance is a placeholder, not a measurement.** ARKit exposes no
pose uncertainty, so the live conformer reports zeros with a `TODO(owner):`.
Zero is not a claim that the error is zero — it is an admission that the number
does not exist yet. It comes from the fitted model, which is still ahead.

**`@unchecked Sendable` is honest, not proven.** The stream continuation is
written once and read from ARKit's delegate context. `ARSessionDelegate`
serialises its callbacks, but Swift cannot see that, so `@unchecked` is me
telling the compiler I have reasoned about something it cannot check. If this
ever needs to be stricter, a lock is the natural hardening. I would rather have
the annotation and know why it is there than have a proof I did not write.

**The iOS-only file is now type-checked.** `swift test` on the Mac skips
`SensorSource` entirely, so committing it meant shipping 74 lines a compiler had
never seen. `xcodebuild -scheme SpatialCapture-Package -destination
'generic/platform=iOS' build` fixes that without a device: the log shows ARKit's
module being loaded and `SensorSource.swift` compiling for `arm64-apple-ios18.0`
against `iPhoneOS26.5.sdk`. **BUILD SUCCEEDED.** It has still never *run* — no
frame has ever gone through it — but "compiles against the real SDK" and "I
think I remembered the API" are different claims and only one of them is now
true.

**Commit 1's devlog paid for itself in one commit.** It noted that `platforms:`
declared only iOS and that macOS worked by fallback. `AsyncThrowingStream`
required `.macOS(.v13)` to be declared explicitly, and because the note existed
that was a twenty-second fix instead of twenty minutes of confusion.
