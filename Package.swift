// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Totality",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "TotalityCore", targets: ["TotalityCore"]),
        .library(name: "TotalityUI", targets: ["TotalityUI"]),
        .library(name: "TotalityReader", targets: ["TotalityReader"]),
        .library(name: "TotalityCalendar", targets: ["TotalityCalendar"]),
        .library(name: "TotalityWeb", targets: ["TotalityWeb"]),
        .library(name: "TotalityMail", targets: ["TotalityMail"]),
        .library(name: "TotalityPhotos", targets: ["TotalityPhotos"]),
        .library(name: "TotalityAccount", targets: ["TotalityAccount"]),
        .library(name: "TotalityMessages", targets: ["TotalityMessages"]),
        .library(name: "TotalityTasks", targets: ["TotalityTasks"]),
        .library(name: "TotalitySocial", targets: ["TotalitySocial"]),
        .library(name: "TotalityWeather", targets: ["TotalityWeather"]),
        .library(name: "TotalityClock", targets: ["TotalityClock"]),
        .library(name: "TotalityContacts", targets: ["TotalityContacts"]),
        .library(name: "TotalityHiking", targets: ["TotalityHiking"]),
        .library(name: "TotalityAI", targets: ["TotalityAI"]),
        .library(name: "TotalityMusic", targets: ["TotalityMusic"]),
    ],
    dependencies: [
        .package(url: "https://github.com/jedisct1/swift-sodium.git", exact: "0.9.1"),
        .package(url: "https://github.com/supabase/supabase-swift.git", exact: "2.49.0"),
        .package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.18.0"),
    ],
    targets: [
        .binaryTarget(
            name: "llama",
            url: "https://github.com/ggml-org/llama.cpp/releases/download/b8851/llama-b8851-xcframework.zip",
            checksum: "f5eb26820b9890ae026aee4963cd4f43af1c567d39534012f2685601a59c2519"
        ),
        .target(name: "TotalityCore", dependencies: [
            .product(name: "Sodium", package: "swift-sodium"),
        ]),
        .target(name: "TotalityUI", dependencies: ["TotalityCore"]),
        .target(name: "TotalityReader", dependencies: [
            "TotalityCore", "TotalityUI",
            .product(name: "FluidAudio", package: "FluidAudio"),
        ], resources: [.copy("Resources/Editor")]),
        .target(name: "TotalityCalendar", dependencies: ["TotalityCore", "TotalityUI"]),
        .target(name: "TotalityWeb", dependencies: ["TotalityCore", "TotalityUI"], resources: [.copy("Resources/blocklist.json")]),
        .target(name: "TotalityMail", dependencies: ["TotalityCore", "TotalityUI"]),
        .target(name: "TotalityPhotos", dependencies: ["TotalityCore", "TotalityUI"]),
        .target(name: "TotalityAccount", dependencies: [
            "TotalityCore", "TotalityUI",
            .product(name: "Supabase", package: "supabase-swift"),
        ]),
        // The Matrix SDK ships for iPhone only, so the app links it and holds the one file that uses it
        // (App/Totality/MatrixMessagesService.swift). That keeps `swift test` working on the Mac.
        .target(name: "TotalityMessages", dependencies: ["TotalityCore", "TotalityUI"]),
        .target(name: "TotalityTasks", dependencies: ["TotalityCore", "TotalityUI"]),
        .target(name: "TotalitySocial", dependencies: ["TotalityCore", "TotalityUI"]),
        .target(name: "TotalityWeather", dependencies: ["TotalityCore", "TotalityUI"]),
        // AlarmKit is iPhone only, so the one file that uses it is behind `canImport(AlarmKit)`.
        .target(name: "TotalityClock", dependencies: ["TotalityCore", "TotalityUI"]),
        .target(name: "TotalityContacts", dependencies: ["TotalityCore", "TotalityUI"]),
        .target(name: "TotalityHiking", dependencies: ["TotalityCore", "TotalityUI"]),
        .target(name: "TotalityAI", dependencies: ["TotalityCore", "TotalityUI", "llama"]),
        .target(name: "TotalityMusic", dependencies: ["TotalityCore", "TotalityUI"]),
        .testTarget(name: "TotalityCoreTests", dependencies: ["TotalityCore"]),
        .testTarget(name: "TotalityUITests", dependencies: ["TotalityUI"]),
        .testTarget(name: "TotalityReaderTests", dependencies: ["TotalityReader"]),
        .testTarget(name: "TotalityCalendarTests", dependencies: ["TotalityCalendar"]),
        .testTarget(name: "TotalityWebTests", dependencies: ["TotalityWeb"]),
        .testTarget(name: "TotalityMailTests", dependencies: ["TotalityMail"]),
        .testTarget(name: "TotalityPhotosTests", dependencies: ["TotalityPhotos"]),
        .testTarget(name: "TotalityAccountTests", dependencies: ["TotalityAccount"]),
        .testTarget(name: "TotalityMessagesTests", dependencies: ["TotalityMessages"]),
        .testTarget(name: "TotalityTasksTests", dependencies: ["TotalityTasks"]),
        .testTarget(name: "TotalitySocialTests", dependencies: ["TotalitySocial"]),
        .testTarget(name: "TotalityWeatherTests", dependencies: ["TotalityWeather"]),
        .testTarget(name: "TotalityClockTests", dependencies: ["TotalityClock"]),
        .testTarget(name: "TotalityContactsTests", dependencies: ["TotalityContacts"]),
        .testTarget(name: "TotalityHikingTests", dependencies: ["TotalityHiking"]),
        .testTarget(name: "TotalityAITests", dependencies: ["TotalityAI"]),
        .testTarget(name: "TotalityMusicTests", dependencies: ["TotalityMusic"]),
    ]
)
