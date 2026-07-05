// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ChromiumKit",
    platforms: [.macOS(.v12)],
    products: [
        // Full surface for the host app — links Chromium Embedded Framework.
        .library(name: "ChromiumKit", targets: ["ChromiumKit"]),
        // Minimal surface for helper sub-process executables. Does NOT pull in
        // the CCEF binary framework, so SPM/clang doesn't bake a host-shaped
        // @executable_path/../Frameworks/... load command into the helper.
        // The helper dlopens the framework at runtime via CefScopedLibraryLoader.
        .library(name: "ChromiumKitHelper", targets: ["ChromiumKitHelper"])
    ],
    targets: [
        // Prebuilt Chromium Embedded Framework, distributed as an XCFramework
        // attached to a GitHub Release. SPM downloads + caches it on resolution.
        // CEF 144.0.28+ga64d412+chromium-144.0.7559.255 (arm64 only).
        .binaryTarget(
            name: "CCEF",
            url: "https://github.com/breath103/CEFKit/releases/download/v0.1.1/CEF.xcframework.zip",
            checksum: "a73c43f8e4ad477c12d3e47cf93a1d0791a688f6e28acd6c010469bc58ecb5e1"
        ),

        // CEF's libcef_dll wrapper. Vendored from the CEF binary distribution
        // (BSD-licensed). Compiled in-tree on the consumer machine.
        .target(
            name: "ChromiumWrapper",
            path: "Sources/ChromiumWrapper",
            exclude: [
                "libcef_dll/CMakeLists.txt"
            ],
            sources: ["libcef_dll"],
            publicHeadersPath: "include",
            cxxSettings: [
                .headerSearchPath("."),
                .define("__STDC_CONSTANT_MACROS"),
                .define("__STDC_FORMAT_MACROS"),
                .define("USING_CEF_SHARED"),
                .define("WRAPPING_CEF_SHARED")
                // NB: don't add unsafeFlags here — SPM rejects packages that
                // consume binaryTargets via URL if any transitively-linked
                // target uses unsafeFlags. We tolerate the -Wundefined-var-template
                // warnings (5 of them) on first build instead.
            ]
        ),

        // Obj-C++ glue: owns CefBrowser, implements CefClient handlers,
        // exposes a thin Obj-C surface that Swift can import.
        .target(
            name: "ChromiumViewObjC",
            dependencies: ["ChromiumWrapper"],
            path: "Sources/ChromiumViewObjC",
            publicHeadersPath: "include",
            cxxSettings: [
                .headerSearchPath("../ChromiumWrapper"),
                .define("__STDC_CONSTANT_MACROS"),
                .define("__STDC_FORMAT_MACROS"),
                .define("USING_CEF_SHARED")
            ]
        ),

        // Public Swift API: re-exports + sugar (typed/async evaluateJavaScript,
        // ChromiumConfiguration convenience init). Marquee type is ChromiumWebView.
        .target(
            name: "ChromiumKit",
            dependencies: ["ChromiumViewObjC", "CCEF"],
            path: "Sources/ChromiumKit"
        ),

        // Helper sub-process facade — no CCEF dep.
        .target(
            name: "ChromiumKitHelper",
            dependencies: ["ChromiumViewObjC"],
            path: "Sources/ChromiumKitHelper"
        ),

        .testTarget(
            name: "ChromiumKitTests",
            dependencies: ["ChromiumKit"],
            path: "Tests/ChromiumKitTests"
        )
    ],
    cxxLanguageStandard: .cxx17
)
