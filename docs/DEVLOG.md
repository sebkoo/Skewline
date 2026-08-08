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
