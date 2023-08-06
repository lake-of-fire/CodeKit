// swift-tools-version: 5.8

import PackageDescription

let package = Package(
    name: "CodeMirror",
    platforms: [.iOS(.v16), .macOS(.v13)],
    products: [
        .library(
            name: "CodeLibrary",
            targets: ["CodeLibrary"]),
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
    dependencies: [
        .package(url: "https://github.com/realm/realm-swift.git", from: "10.28.1"),
        .package(url: "https://github.com/lake-of-fire/opml", branch: "master"),
        .package(url: "https://github.com/lake-of-fire/FilePicker.git", branch: "main"),
        .package(url: "https://github.com/lake-of-fire/BigSyncKit.git", branch: "main"),
        .package(url: "https://github.com/lake-of-fire/swiftui-webview.git", branch: "main"),
        .package(url: "https://github.com/satoshi-takano/OpenGraph.git", branch: "main"),
        .package(url: "https://github.com/lake-of-fire/RealmSwiftGaps.git", branch: "main"),
//        .package(url: "https://github.com/Tunous/DebouncedOnChange.git", branch: "main"),
        .package(url: "https://github.com/lake-of-fire/SwiftUtilities.git", branch: "main"),
        .package(url: "https://github.com/lake-of-fire/SwiftUIDownloads.git", branch: "main"),
        .package(url: "https://github.com/thebaselab/FileProvider.git", branch: "master"),
        .package(url: "https://github.com/lake-of-fire/SwiftGit2.git", branch: "main"), // MBoxSpace/SwiftGit2 also interesting
    ],
    targets: [
        .target(
            name: "CodeCore",
            dependencies: [
                .product(name: "Realm", package: "realm-swift"),
                .product(name: "RealmSwift", package: "realm-swift"),
                .product(name: "BigSyncKit", package: "BigSyncKit"),
                .product(name: "FilesProvider", package: "FileProvider"),
                .product(name: "SwiftGit2", package: "SwiftGit2"),
            ],
            exclude: [
                "src/node_modules",
                "src/codecore.js",
                "src/rollup.config.mjs",
                "src/package.json",
                "src/package-lock.json",
            ],
            resources: [
                .copy("src"),
            ]),
        .target(
            name: "CodeLibrary",
            dependencies: [
                .target(name: "CodeCore"),
                .product(name: "OPML", package: "OPML"),
                .product(name: "FilePicker", package: "FilePicker"),
                .product(name: "Realm", package: "realm-swift"),
                .product(name: "RealmSwift", package: "realm-swift"),
                .product(name: "RealmSwiftGaps", package: "RealmSwiftGaps"),
                .product(name: "SwiftUIWebView", package: "swiftui-webview"),
                .product(name: "SwiftUtilities", package: "SwiftUtilities"),
                .product(name: "SwiftUIDownloads", package: "SwiftUIDownloads"),
//                .product(name: "DebouncedOnChange", package: "DebouncedOnChange"),
            ],
            resources: [
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
