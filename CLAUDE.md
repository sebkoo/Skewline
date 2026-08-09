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

Acyclic, `Core` at the root. `Replay` must never depend on `Capture`. Replay is
what makes the pipeline testable without hardware, so anything it imports
becomes a thing the tests drag along.

## The gate

`swift build && swift test`, in the terminal, before staging. Xcode cannot run a
tool-hosted test target against a device destination.

The whole suite runs on a Mac with no device attached. `canImport(ARKit)` is
**true** on macOS — a stub ships in the SDK — so iOS-only code needs
`#if canImport(ARKit) && os(iOS)`, and code inside a false branch is not
type-checked on that host. Confirm it compiles for the device with
xcodebuild -scheme Skewline-Package -destination 'generic/platform=iOS' build

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
