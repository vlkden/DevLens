// swift-tools-version: 5.9
//
//  Package.swift
//  DevLens
//
//  Created by Denys Volkov.
//  MIT License.
//

import PackageDescription

let package = Package(
    name: "DevLens",
    platforms: [
        .iOS(.v13),
        .macOS(.v10_15),
    ],
    products: [
        // Umbrella: everything in one import.
        .library(name: "DevLens", targets: ["DevLens"]),
        // Individual modules so an app can depend on just one.
        .library(name: "APITrace", targets: ["APITrace"]),
        // Offline before/after comparison of two exported traces.
        .executable(name: "trace-compare", targets: ["trace-compare"]),
    ],
    targets: [
        .target(name: "DevLens", dependencies: ["APITrace"]),
        .target(name: "APITrace"),
        .executableTarget(name: "trace-compare", dependencies: ["APITrace"]),
        .testTarget(name: "APITraceTests", dependencies: ["APITrace"]),
    ],
    swiftLanguageVersions: [.v5]
)
