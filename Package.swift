// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "CodeKit",
    platforms: [.iOS(.v16), .macOS(.v13)],
    products: [
        .library(name: "CodeLibrary", targets: ["CodeLibrary"]),
        .library(name: "CodeAI", targets: ["CodeAI"]),
        .library(name: "CodeEditor", targets: ["CodeEditor"]),
        .library(name: "CodeCI", targets: ["CodeCI"]),
        .library(name: "CodeRunner", targets: ["CodeRunner"]),
    ],
    dependencies: [
        .package(url: "https://github.com/lake-of-fire/RealmBinary.git", branch: "main"),
        .package(url: "https://github.com/lake-of-fire/opml", branch: "master"),
        .package(url: "https://github.com/lake-of-fire/FilePicker.git", branch: "main"),
        .package(url: "https://github.com/lake-of-fire/BigSyncKit.git", branch: "main"),
        .package(url: "https://github.com/lake-of-fire/swiftui-webview.git", branch: "main"),
        .package(url: "https://github.com/lake-of-fire/RealmSwiftGaps.git", branch: "main"),
        .package(url: "https://github.com/lake-of-fire/SwiftUtilities.git", branch: "main"),
        .package(url: "https://github.com/lake-of-fire/SwiftUIDownloads.git", branch: "main"),
        .package(url: "https://github.com/thebaselab/FileProvider.git", branch: "master"),
        .package(url: "https://github.com/lake-of-fire/SwiftGit2.git", branch: "main"),
        .package(url: "https://github.com/lake-of-fire/SwiftWhisperStream.git", branch: "master"),
        .package(url: "https://github.com/Tunous/DebouncedOnChange.git", branch: "main"),
    ],
    targets: [
        .target(
            name: "CodeCore",
            dependencies: [
                .product(name: "Realm", package: "RealmBinary"),
                .product(name: "RealmSwift", package: "RealmBinary"),
                .product(name: "BigSyncKit", package: "BigSyncKit"),
                .product(name: "FilesProvider", package: "FileProvider"),
                .product(name: "SwiftGit2", package: "SwiftGit2"),
            ],
            resources: [
                .copy("src/build"),
            ],
            swiftSettings: [.interoperabilityMode(.Cxx)]),
        .target(
            name: "CodeLibrary",
            dependencies: [
                .target(name: "CodeCore"),
                .target(name: "CodeCI"),
                .target(name: "CodeAI"),
                .product(name: "OPML", package: "OPML"),
                .product(name: "FilePicker", package: "FilePicker"),
                .product(name: "Realm", package: "RealmBinary"),
                .product(name: "RealmSwift", package: "RealmBinary"),
                .product(name: "RealmSwiftGaps", package: "RealmSwiftGaps"),
                .product(name: "SwiftUIWebView", package: "swiftui-webview"),
                .product(name: "SwiftUtilities", package: "SwiftUtilities"),
                .product(name: "SwiftUIDownloads", package: "SwiftUIDownloads"),
            ],
            swiftSettings: [.interoperabilityMode(.Cxx)]),
        .target(
            name: "CodeAI",
            dependencies: [
                .target(name: "CodeCore"),
                .target(name: "CodeRunner"),
                .product(name: "Realm", package: "RealmBinary"),
                .product(name: "RealmSwift", package: "RealmBinary"),
                .product(name: "BigSyncKit", package: "BigSyncKit"),
                .product(name: "RealmSwiftGaps", package: "RealmSwiftGaps"),
                .product(name: "SwiftUtilities", package: "SwiftUtilities"),
                .product(name: "SwiftUIDownloads", package: "SwiftUIDownloads"),
                .product(name: "DebouncedOnChange", package: "DebouncedOnChange"),
                .product(name: "SwiftLlama", package: "SwiftWhisperStream"),
                .product(name: "SwiftWhisperStream", package: "SwiftWhisperStream"),
            ],
            swiftSettings: [.interoperabilityMode(.Cxx)]),
        .target(
            name: "CodeEditor",
            dependencies: [
                .target(name: "CodeCore"),
            ]),
        .target(
            name: "CodeCI",
            dependencies: [
                .target(name: "CodeCore"),
            ],
            swiftSettings: [.interoperabilityMode(.Cxx)]),
        .target(
            name: "CodeRunner",
            dependencies: [
                .target(name: "CodeCore"),
                .product(name: "Realm", package: "RealmBinary"),
                .product(name: "RealmSwift", package: "RealmBinary"),
            ],
            swiftSettings: [.interoperabilityMode(.Cxx)]),
    ]
)
