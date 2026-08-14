// Fails when the README contradicts the repository. Detection only: the fix
// is a human docs commit, never a bot's.
//
// Every assertion here is mechanically falsifiable, and each failure quotes
// the claim it caught verbatim. Three designs are deliberate:
//
// - A negative claim ("No app") is checked only while its exact text appears
//   in the README, so correcting the README retires the probe without
//   touching this script. The table polices the claims it lists, nothing
//   more.
// - A structural anchor -- the ladder, the module list, the CI job count --
//   is required. A check that silently skips when its anchor disappears is
//   decoration, which is the lesson the commit-msg hook taught.
// - One anchor is conditional, and the cost is said rather than hidden. The
//   ROADMAP's what-is-next table is required to have rows only while the
//   ladder still has an unfinished rung; a ladder whose every rung is done
//   has ended, and a table with no rows is that state's honest shape. The
//   table itself stays required, so "empty" stays distinguishable from
//   "deleted", and the next rung to arrive re-arms the row requirement.
//
// What none of this can catch: prose that is wrong without being falsifiable,
// a claim reworded until the verbatim match misses, a ladder truncated to a
// fully-done prefix rather than ended, and the README agreeing with a ROADMAP
// that is itself wrong. Agreement is not truth.
//
// Run from the repository root: swift Scripts/readme-drift.swift

import Foundation

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
var failures: [String] = []

func fail(claim: String, because reason: String) {
    failures.append("README claims \"\(claim)\" -- \(reason)")
}

func read(_ path: String) -> String? {
    try? String(contentsOf: root.appending(path: path), encoding: .utf8)
}

guard let readme = read("README.md") else {
    print("readme-drift: README.md not found at \(root.path)")
    exit(1)
}
let readmeLines = readme.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)

// MARK: - Assertion 1: negative-existence claims against the tree

/// The first path under the repository with the given extension, ignoring
/// build products and version control.
func firstPath(withExtension ext: String) -> String? {
    let enumerator = FileManager.default.enumerator(
        at: root,
        includingPropertiesForKeys: nil
    )
    while let url = enumerator?.nextObject() as? URL {
        let relative = url.path.dropFirst(root.path.count + 1)
        let components = relative.split(separator: "/")
        if components.first == ".git" || components.contains(".build") || components.contains("DerivedData") || components.contains(".venv") {
            enumerator?.skipDescendants()
            continue
        }
        if url.pathExtension == ext {
            return String(relative)
        }
    }
    return nil
}

/// The first path under the repository whose **first line** begins with the
/// given prefix, ignoring build products and version control.
///
/// First line and not "contains", deliberately. An export *begins* with its
/// schema tag; a source file that merely mentions the tag -- `Fit/fit.py`
/// declares it as a constant, `Fit/test_fit.py` embeds a whole fixture that
/// starts with it several lines in -- does not. That distinction is the whole
/// check: it catches the artifact and never the code that reads it.
func firstPath(withFirstLine prefix: String) -> String? {
    let enumerator = FileManager.default.enumerator(
        at: root,
        includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey]
    )
    while let url = enumerator?.nextObject() as? URL {
        let relative = url.path.dropFirst(root.path.count + 1)
        let components = relative.split(separator: "/")
        if components.first == ".git" || components.contains(".build") || components.contains("DerivedData") || components.contains(".venv") {
            enumerator?.skipDescendants()
            continue
        }
        guard
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey]),
            values.isRegularFile == true,
            let handle = try? FileHandle(forReadingFrom: url)
        else { continue }
        defer { try? handle.close() }
        // One short read per file: a schema tag is the first thing in the
        // file or it is not there at all, so nothing needs the whole export
        // in memory to be refused.
        let head = (try? handle.read(upToCount: 256)) ?? Data()
        guard let text = String(data: head, encoding: .utf8) else { continue }
        let firstLine = text.split(separator: "\n", omittingEmptySubsequences: false).first ?? ""
        if firstLine.hasPrefix(prefix) {
            return String(relative)
        }
    }
    return nil
}

let negativeClaims: [(claim: String, contradiction: () -> String?)] = [
    ("No app", {
        firstPath(withExtension: "xcodeproj").map { "an app project exists at \($0)" }
    }),
    ("no rendering", {
        firstPath(withExtension: "metal").map { "a Metal source exists at \($0)" }
    }),
    // The privacy line, made mechanical. Observation exports derive from home
    // captures and never enter the tree; a `/2` file additionally carries a
    // frame index and a pixel per row, which is a subsampled depth image of a
    // room. Both schemas are refused, because the rule predates the second.
    ("No observation export is committed", {
        firstPath(withFirstLine: "# skewline-observations/")
            .map { "an observation export is committed at \($0)" }
    }),
]
for entry in negativeClaims where readme.contains(entry.claim) {
    if let reason = entry.contradiction() {
        fail(claim: entry.claim, because: reason)
    }
}

// MARK: - Assertion 2: the ladder agrees with the ROADMAP

struct LadderRow {
    let version: String
    let name: String
    let marker: String?
}

let markerWords: Set<String> = ["done", "next", "here"]
let ladder: [LadderRow] = readmeLines.compactMap { line in
    let parts = line.split(separator: " ").map(String.init)
    guard parts.count >= 2, let first = parts.first,
          first.hasPrefix("v"), first.dropFirst().contains(".") ,
          first.dropFirst().allSatisfy({ $0.isNumber || $0 == "." }) else { return nil }
    let last = parts.last!
    return LadderRow(
        version: first,
        name: parts[1],
        marker: markerWords.contains(last) ? last : nil
    )
}

if ladder.isEmpty {
    fail(claim: "Where this goes", because: "no ladder rows (vX.Y ...) were found to check")
}

let doneRows = ladder.enumerated().filter { $0.element.marker == "done" }
let currentRows = ladder.enumerated().filter { $0.element.marker == "next" || $0.element.marker == "here" }

/// A ladder whose every rung is done has ended, and an ended ladder is a
/// state rather than a drift: no row is current, and the what-is-next table
/// below has no rows. The two are only ever green together -- a table that
/// empties while a rung is still current is the parse failure this assertion
/// exists to catch, and a ladder that ends while the table still lists a rung
/// is a half-finished edit the row loop below catches by name.
let ladderHasEnded = !ladder.isEmpty && doneRows.count == ladder.count

if !ladder.isEmpty {
    if doneRows.map(\.offset) != Array(0..<doneRows.count) {
        fail(claim: "done", because: "the ladder's done marks are not a prefix of the ladder")
    }
    if ladderHasEnded {
        // Every rung done: nothing may be current, and nothing is.
    } else if currentRows.count != 1 {
        fail(claim: "next", because: "the ladder marks \(currentRows.count) current rungs; exactly one row may be next/here until the last rung is done")
    } else if currentRows[0].offset != doneRows.count {
        fail(claim: currentRows[0].element.marker!, because: "the current rung does not sit immediately after the done prefix")
    }
}

guard let roadmap = read("docs/ROADMAP.md") else {
    print("readme-drift: docs/ROADMAP.md not found")
    exit(1)
}
let roadmapRows: [(version: String, name: String)] = roadmap
    .split(separator: "\n")
    .compactMap { line in
        guard line.hasPrefix("| **v") else { return nil }
        let trimmed = line.dropFirst("| **".count)
        guard let close = trimmed.range(of: "**") else { return nil }
        let version = String(trimmed[..<close.lowerBound])
        let name = trimmed[close.upperBound...]
            .split(separator: " ").first.map(String.init) ?? ""
        return (version, name)
    }

// The table's header, kept verbatim when the last row goes, so that a table
// with nothing outstanding stays legible as one. This literal is load-bearing:
// it is what tells an empty table apart from a deleted section.
let nextTableHeader = "| Version | Ships | What forces it |"

if roadmapRows.isEmpty {
    if !ladderHasEnded {
        fail(claim: "ROADMAP", because: "no table rows (| **vX.Y** name |) were found in docs/ROADMAP.md to check, and the ladder has not ended")
    } else if !roadmap.contains(nextTableHeader) {
        fail(claim: "ROADMAP", because: "the ladder has ended, so the what-is-next table may carry no rows -- but the table itself is gone from docs/ROADMAP.md, and an empty table is a state where a missing one is drift")
    }
}

for row in roadmapRows {
    guard let ladderRow = ladder.first(where: { $0.version == row.version }) else {
        fail(claim: row.version, because: "the ROADMAP lists \(row.version) \(row.name) and the ladder does not")
        continue
    }
    if ladderRow.name != row.name {
        fail(
            claim: "\(row.version)  \(ladderRow.name)",
            because: "the ROADMAP names that rung \"\(row.name)\""
        )
    }
    if ladderRow.marker == "done" {
        fail(
            claim: "\(row.version)  \(ladderRow.name)  done",
            because: "the ROADMAP still lists \(row.version) in its what-is-next table"
        )
    }
}

// MARK: - Assertion 3: the module list agrees with Package.swift

func matches(of pattern: String, in text: String) -> [String] {
    guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
    let range = NSRange(text.startIndex..., in: text)
    return regex.matches(in: text, range: range).compactMap {
        Range($0.range(at: 1), in: text).map { String(text[$0]) }
    }
}

let readmeModules = Set(matches(of: #"\*\*`([A-Za-z]+)`\*\*"#, in: readme))
guard let manifest = read("Package.swift") else {
    print("readme-drift: Package.swift not found")
    exit(1)
}
let products = Set(matches(of: #"\.library\(name: "([A-Za-z]+)""#, in: manifest))

if readmeModules.isEmpty {
    fail(claim: "What is here today", because: "no bolded module names were found to check")
} else if readmeModules != products {
    let missing = products.subtracting(readmeModules).sorted().joined(separator: ", ")
    let extra = readmeModules.subtracting(products).sorted().joined(separator: ", ")
    var reasons: [String] = []
    if !missing.isEmpty { reasons.append("Package.swift also ships: \(missing)") }
    if !extra.isEmpty { reasons.append("Package.swift does not ship: \(extra)") }
    fail(claim: readmeModules.sorted().joined(separator: ", "), because: reasons.joined(separator: "; "))
}

// MARK: - Assertion 4: the stated CI job count agrees with ci.yml

let numberWords = [
    "one": 1, "two": 2, "three": 3, "four": 4, "five": 5,
    "six": 6, "seven": 7, "eight": 8, "nine": 9, "ten": 10,
]

guard let workflow = read(".github/workflows/ci.yml") else {
    print("readme-drift: .github/workflows/ci.yml not found")
    exit(1)
}
var jobNames: [String] = []
var inJobs = false
for line in workflow.split(separator: "\n", omittingEmptySubsequences: false) {
    if line == "jobs:" { inJobs = true; continue }
    guard inJobs else { continue }
    if let first = line.first, first != " " { inJobs = false; continue }
    // A job is a key indented exactly two spaces under `jobs:`.
    if line.hasPrefix("  "), !line.hasPrefix("   "),
       let name = line.dropFirst(2).split(separator: ":").first,
       line.trimmingCharacters(in: .whitespaces).hasSuffix(":") {
        jobNames.append(String(name))
    }
}

let statedCounts = matches(of: #"([A-Za-z]+) CI jobs"#, in: readme)
if statedCounts.isEmpty {
    fail(claim: "CI jobs", because: "no \"<number> CI jobs\" sentence was found to check")
} else {
    for word in statedCounts {
        guard let stated = numberWords[word.lowercased()] else {
            fail(claim: "\(word) CI jobs", because: "\"\(word)\" is not a number this check can read")
            continue
        }
        if stated != jobNames.count {
            fail(
                claim: "\(word) CI jobs",
                because: "ci.yml defines \(jobNames.count): \(jobNames.joined(separator: ", "))"
            )
        }
    }
}

// MARK: - Verdict

if failures.isEmpty {
    print("readme-drift: README agrees with the repository")
    exit(0)
}
for failure in failures {
    print("readme-drift: \(failure)")
}
exit(1)
