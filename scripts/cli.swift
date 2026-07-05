#!/usr/bin/env swift
//
// cli.swift — typed dev runner for ChromiumKit (tests + CI build steps).
//
// Runs the HelloChromium example's test targets against the real app. Fetches
// the CEF framework first if vendor/cef/ is missing (one-time ~265MB download).
//
//   scripts/cli.swift            # list subcommands
//   scripts/cli.swift ui         # all UI tests
//   scripts/cli.swift unit       # all unit tests
//   scripts/cli.swift ui --help  # per-subcommand help
//
import Foundation

// MARK: - Paths

let root = URL(fileURLWithPath: #filePath)
    .resolvingSymlinksInPath()
    .deletingLastPathComponent() // scripts/
    .deletingLastPathComponent() // repo root
let project = root.appendingPathComponent("Examples/HelloChromium/HelloChromium.xcodeproj")
let cefFramework = root.appendingPathComponent("vendor/cef/Release/Chromium Embedded Framework.framework")
let fetchScript = root.appendingPathComponent("scripts/fetch-cef.sh")

// MARK: - Process helper

/// Run a command, streaming its output to our terminal, and return its exit code.
@discardableResult
func run(_ launchPath: String, _ arguments: [String], cwd: URL? = nil) -> Int32 {
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: launchPath)
    proc.arguments = arguments
    if let cwd { proc.currentDirectoryURL = cwd }
    do {
        try proc.run()
    } catch {
        FileHandle.standardError.write(Data("error: failed to launch \(launchPath): \(error)\n".utf8))
        return 127
    }
    proc.waitUntilExit()
    return proc.terminationStatus
}

/// CEF isn't in git. The Xcode embed step needs the framework on disk — fetch once.
func ensureCEF() -> Int32 {
    if FileManager.default.fileExists(atPath: cefFramework.path) { return 0 }
    print("==> vendor/cef missing — fetching CEF (one-time, ~265MB download)")
    return run("/bin/bash", [fetchScript.path])
}

/// Code-signing args for xcodebuild. Defaults to ad-hoc ("-") so CI and fresh
/// checkouts work with no setup. Export `CHROMIUMKIT_SIGN_IDENTITY` (from your
/// shell — direnv, a sourced `.env`, or your profile) to a stable local identity
/// (e.g. a self-signed "ChromiumKit Local" cert from
/// scripts/make-signing-identity.sh) and macOS keeps your Keychain "Always Allow"
/// and XCTest automation grants across rebuilds — ad-hoc signing gets a fresh
/// identity every build, so those grants re-prompt forever otherwise.
func signingArgs() -> [String] {
    let identity = ProcessInfo.processInfo.environment["CHROMIUMKIT_SIGN_IDENTITY"] ?? "-"
    return ["CODE_SIGN_STYLE=Manual", "CODE_SIGN_IDENTITY=\(identity)"]
}

/// Build + run one test target, optionally narrowed to a `Class` or `Class/method`.
func xcodebuildTest(target: String, filter: String?) -> Int32 {
    if case let code = ensureCEF(), code != 0 { return code }
    let onlyTesting = filter.map { "\(target)/\($0)" } ?? target
    print("==> xcodebuild test (\(onlyTesting))")
    return run("/usr/bin/xcodebuild", [
        "test",
        "-project", project.path,
        "-scheme", "HelloChromium",
        "-destination", "platform=macOS",
        "-only-testing:\(onlyTesting)"
    ] + signingArgs())
}

/// Locate an executable on PATH (like `which`). Returns its path, or nil if absent.
func which(_ tool: String) -> String? {
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    proc.arguments = ["which", tool]
    let pipe = Pipe()
    proc.standardOutput = pipe
    proc.standardError = FileHandle.nullDevice
    try? proc.run()
    proc.waitUntilExit()
    guard proc.terminationStatus == 0 else { return nil }
    let out = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        .trimmingCharacters(in: .whitespacesAndNewlines)
    return out.isEmpty ? nil : out
}

/// The `swift-build` CI job: resolve the package, download + checksum the
/// CEF.xcframework, compile the wrapper.
func swiftBuildRelease() -> Int32 {
    print("==> swift build -c release")
    return run("/usr/bin/env", ["swift", "build", "-c", "release"], cwd: root)
}

/// The `xcode-build-hellocef` CI job: regenerate the project from project.yml
/// (when xcodegen is installed, as CI does) and build it for arm64.
func xcodeBuildExample() -> Int32 {
    let cef = ensureCEF()
    if cef != 0 { return cef }
    let hello = root.appendingPathComponent("Examples/HelloChromium")
    if which("xcodegen") != nil {
        print("==> xcodegen generate")
        let gen = run("/usr/bin/env", ["xcodegen", "generate"], cwd: hello)
        if gen != 0 { return gen }
    } else {
        print("==> xcodegen not installed — building the committed .xcodeproj (CI regenerates it; brew install xcodegen to match)")
    }
    print("==> xcodebuild build (HelloChromium, arm64)")
    return run("/usr/bin/xcodebuild", [
        "-project", "HelloChromium.xcodeproj",
        "-scheme", "HelloChromium",
        "-configuration", "Debug",
        "-destination", "platform=macOS,arch=arm64",
        "ONLY_ACTIVE_ARCH=YES",
        "CODE_SIGN_STYLE=Manual",
        "CODE_SIGN_IDENTITY=-",
        "build"
    ], cwd: hello)
}

// MARK: - Subcommand model

struct Subcommand {
    let name: String
    let summary: String // one line, shown in the top-level list
    let usage: String // argument shape, shown in `<cmd> --help`
    let discussion: String // longer help body
    let examples: [String]
    let run: (_ args: [String]) -> Int32

    func printHelp() {
        let invocation = usage.isEmpty
            ? "scripts/cli.swift \(name)"
            : "scripts/cli.swift \(name) \(usage)"
        print("""
        \(summary)

        USAGE
          \(invocation)

        \(discussion)

        EXAMPLES
        """)
        for ex in examples {
            print("  \(ex)")
        }
    }
}

/// A test subcommand: bare target run, or narrowed by an optional `Class[/method]` arg.
func testSubcommand(
    name: String, target: String, summary: String, suiteHint: String, examples: [String]
) -> Subcommand {
    Subcommand(
        name: name,
        summary: summary,
        usage: "[TestClass[/testMethod]]",
        discussion: """
        Runs the \(target) target. \(suiteHint)

        With no argument the whole target runs. Pass a test-class name to run just
        that class, or Class/method to run a single test.
        """,
        examples: examples
    ) { args in
        // Reject stray flags so typos surface instead of silently running everything.
        let positionals = args.filter { !$0.hasPrefix("-") }
        if let bad = args.first(where: { $0.hasPrefix("-") }) {
            FileHandle.standardError.write(Data("error: unknown option '\(bad)' (try: scripts/cli.swift \(name) --help)\n".utf8))
            return 2
        }
        if positionals.count > 1 {
            FileHandle.standardError.write(Data("error: expected at most one test filter, got \(positionals.count)\n".utf8))
            return 2
        }
        return xcodebuildTest(target: target, filter: positionals.first)
    }
}

let subcommands: [Subcommand] = [
    testSubcommand(
        name: "ui",
        target: "HelloChromiumUITests",
        summary: "Run the XCUITest suite (launches the real app + CEF).",
        suiteHint: "These launch HelloChromium, spin up CEF's multi-process engine, "
            + "load live pages, and drive the UI — so a GUI login session is required.",
        examples: [
            "scripts/cli.swift ui",
            "scripts/cli.swift ui AddressBarUITests",
            "scripts/cli.swift ui AddressBarUITests/testEscapeCancelsEdit"
        ]
    ),
    testSubcommand(
        name: "unit",
        target: "HelloChromiumUnitTests",
        summary: "Run the unit-test target (fast, no UI automation).",
        suiteHint: "Lifecycle/retain-cycle checks that don't drive the app window.",
        examples: [
            "scripts/cli.swift unit",
            "scripts/cli.swift unit ChromiumWebViewLifecycleTests"
        ]
    ),
    Subcommand(
        name: "build",
        summary: "swift build -c release (the package CI job).",
        usage: "",
        discussion: """
        Resolves the package, downloads CEF.xcframework from the Release URL in
        Package.swift, verifies its sha256, and compiles the wrapper sources.
        Mirrors the swift-build job in .github/workflows/ci.yml.
        """,
        examples: ["scripts/cli.swift build"]
    ) { _ in swiftBuildRelease() },
    Subcommand(
        name: "xcode",
        summary: "Build Examples/HelloChromium (the xcode CI job).",
        usage: "",
        discussion: """
        Regenerates HelloChromium.xcodeproj from project.yml (if xcodegen is
        installed, as CI does), then builds it for arm64. Mirrors the
        xcode-build-hellocef job in .github/workflows/ci.yml.
        """,
        examples: ["scripts/cli.swift xcode"]
    ) { _ in xcodeBuildExample() },
    Subcommand(
        name: "ci",
        summary: "Run the full CI suite locally (build + xcode).",
        usage: "",
        discussion: """
        Runs `build` then `xcode` — the two jobs in .github/workflows/ci.yml —
        stopping at the first failure. CI itself does not run tests; use the
        `ui` / `unit` commands for those.
        """,
        examples: ["scripts/cli.swift ci"]
    ) { _ in
        let build = swiftBuildRelease()
        if build != 0 { return build }
        return xcodeBuildExample()
    }
]

// MARK: - Top-level dispatch

func printTopLevelHelp() {
    print("""
    cli.swift — typed dev runner for ChromiumKit.

    USAGE
      scripts/cli.swift <command> [args]

    COMMANDS
    """)
    let width = subcommands.map(\.name.count).max() ?? 0
    for cmd in subcommands {
        let pad = String(repeating: " ", count: width - cmd.name.count)
        print("  \(cmd.name)\(pad)  \(cmd.summary)")
    }
    print("""

    Run 'scripts/cli.swift <command> --help' for details on a command.
    The first run fetches CEF (~265MB) into vendor/cef/; later runs reuse it.
    """)
}

let argv = Array(CommandLine.arguments.dropFirst())

guard let first = argv.first else {
    printTopLevelHelp()
    exit(0)
}

if first == "-h" || first == "--help" || first == "help" {
    // `help` / `help <cmd>` and the bare flags.
    if let target = argv.dropFirst().first, let cmd = subcommands.first(where: { $0.name == target }) {
        cmd.printHelp()
    } else {
        printTopLevelHelp()
    }
    exit(0)
}

guard let cmd = subcommands.first(where: { $0.name == first }) else {
    FileHandle.standardError.write(Data("error: unknown command '\(first)' (try: scripts/cli.swift --help)\n".utf8))
    exit(2)
}

let rest = Array(argv.dropFirst())
if rest.contains("-h") || rest.contains("--help") {
    cmd.printHelp()
    exit(0)
}

exit(cmd.run(rest))
