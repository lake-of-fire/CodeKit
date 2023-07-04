// swift-tools-version: 5.7

import PackageDescription

let package = Package(
    name: "CodeMirror",
    platforms: [.iOS(.v16), .macOS(.v13)],
    products: [
        .library(
            name: "CodeEditor",
            targets: ["CodeEditor"]),
        .library(
            name: "CodeCI",
            targets: ["CodeCI"]),
        .library(
            name: "CodeRunner",
            targets: ["CodeRunner"]),
    ],
    dependencies: [],
    targets: [
        .target(
            name: "CodeCore",
            dependencies: [
            ],
            exclude: [
                "src/node_modules",
                "src/editor.js",
                "src/rollup.config.js",
                "src/package.json",
                "src/package-lock.json",
            ],
            resources: [
                .copy("src/build")
            ]),
        .target(
            name: "CodeEditor",
            dependencies: [
                .target(name: "CodeCore"),
            ],
            resources: [
            ]),
        .target(
            name: "CodeCI",
            dependencies: [
                .target(name: "CodeCore"),
            ],
            resources: [
            ]),
        .target(
            name: "CodeRunner",
            dependencies: [
                .target(name: "CodeCore"),
            ],
            resources: [
            ]),
    ]
)
