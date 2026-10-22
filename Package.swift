// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "HerdEye",
    platforms: [
        .macOS(.v26),
    ],
    products: [
        .library(name: "HerdEye", targets: ["HerdEye"]),
    ],
    targets: [
        .target(
            name: "HerdEye",
            path: "HerdEye",
            exclude: [
                "BarDotSettings.swift",
                "BarPopoverView.swift",
                "BarSettingsView.swift",
                "HerdEye.entitlements",
                "HerdEyeApp.swift",
                "HerdEyeIcon.icon",
                "Info.plist",
                "LaunchAtLogin.swift",
                "StatusBarController.swift",
                "Store/PastureStore.swift",
            ],
            sources: [
                "Domain/AgentIdentity.swift",
                "Domain/AgentState.swift",
                "Domain/BarAgentSelection.swift",
                "Domain/PastureAgent.swift",
                "Socket/HerdrClient.swift",
                "Socket/HerdrModels.swift",
                "Socket/HerdrSocketTransport.swift",
                "Socket/HerdrSocketWatcher.swift",
                "Socket/HerdrTransport.swift",
                "Socket/NDJSONLineReader.swift",
                "Store/PastureReducer.swift",
            ]
        ),
        .testTarget(
            name: "HerdEyeTests",
            dependencies: ["HerdEye"],
            path: "HerdEyeTests"
        ),
    ]
)
