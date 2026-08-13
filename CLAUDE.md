# Skewline

A Swift package for spatial capture on iOS. The idea it exists to test: **a
spatial result needs a confidence, not just a coordinate.** A pose estimate
without an uncertainty beside it is a number nobody can act on.

The name is the thesis. In triangulation the two back-projected rays should meet
at the point and never do; they are skew lines, and the length of their common
perpendicular is the residual.

## The graph

- `Core` — types only. No I/O, no dependencies.
- `Replay` — the on-disk session format. Depends on `Core` and nothing else.
- `Capture` — the ingest boundary. Depends on `Core` and `Replay`.
- `Render` — replay-side unprojection: depth pixels into world points, each
  with its confidence. Depends on `Core` and `Replay`, never `Capture`.
- `Interop` — a PLY point-cloud file read across a C seam into the module's
  own value types. Depends on nothing above: the C++ parser is a private
  target behind a pure C header, so no importer inherits a language mode.
- `Model` — the fitted model, read from the service and evaluated locally.
  Depends on nothing above and owns its value types: joining a model to
  rendered points is the consumer's edge, so it never reaches for `Render`'s.
- `Sight` — that consumer's edge: a depth sample and the confidence the sensor
  gave it, into what the model says about that point. Depends on `Model` alone.
  The sensor's 0/1/2 confidence encoding lives here and not in `Model`, because
  `skewline-fit/1` never mentions it.

Acyclic, `Core` at the root. `Replay` must never depend on `Capture`. Replay is
what makes the pipeline testable without hardware, so anything it imports
becomes a thing the tests drag along.

## The gate

Five commands, in the terminal, before staging. Xcode cannot run a
tool-hosted test target against a device destination.

    swift build && swift test
    xcodebuild -scheme Skewline-Package -destination 'generic/platform=iOS' build
    xcodebuild -project App/SkewlineHarness/SkewlineHarness.xcodeproj -scheme SkewlineHarness -destination 'generic/platform=iOS' build CODE_SIGNING_ALLOWED=NO
    .venv/bin/python -m unittest discover -s Fit -v
    swift Scripts/readme-drift.swift

The whole suite runs on a Mac with no device attached. `canImport(ARKit)` is
**true** on macOS — a stub ships in the SDK — so iOS-only code needs
`#if canImport(ARKit) && os(iOS)`, and code inside a false branch is not
type-checked on that host. The second command is what type-checks it for the
device; the third catches the app target's `MainActor` default the package
does not share; the fourth is the fit harness's tests, the service's and the
view's, all in `Fit/` so one command finds them (one-time setup: `python3 -m venv .venv &&
.venv/bin/pip install -r Fit/requirements.txt`); the fifth is the README drift
check CI also runs.

Two Swift 6 facts that bite here: `simd` matrix types are `Sendable` but not
`Codable`, and a `public` struct gets no implicit `Sendable` (SE-0302) with no
diagnostic in synchronous code.

## Not negotiable

- Never invent an API, a version, a number or a name. Unsure means
  `TODO(owner):` plus a line in the report.
- No fabricated measurements. No benchmark, accuracy, latency or frame time for
  code that does not exist. The only placeholder is `not measured yet`.
- No AI attribution anywhere in the history: no `Co-Authored-By:`, no
  `Generated with`, no robot emoji, no session trailer, no trailer of any kind.
- Ordinary technical terms only — reconstruction, photogrammetry, SLAM,
  covariance, plenoptic, light field. For a borderline phrase, search it exactly:
  if every hit traces back to one organisation and its own pages, it is branded,
  however generic it sounds.
- One concern per commit. Stage named paths, never `-A`.
- Conventional Commits: type, colon, space, imperative subject. 50 characters as
  the target and 72 as the wall, no full stop. Body only when there is a *why*
  the diff cannot show. Never restate the diff, never describe the commit rather
  than the change, never list what is not in it.
- Before any `git commit --amend`, run `git log -1 --format='%h %s'` first.
  Amend acts on whatever HEAD happens to be.

## The report

After a change, three things in plain prose, under 120 words: what was built and
any decision satisfied differently than the obvious reading; the exact output of
the gate; and anything in the instructions that was wrong, ambiguous or guessed
at. **The third one matters more than the other two.**
