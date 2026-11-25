// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "MeetingAssistant",
    platforms: [.macOS(.v26)],
    products: [
        .executable(name: "meeting-assistant", targets: ["MeetingAssistantCLI"]),
        .library(name: "MeetingAudio", targets: ["MeetingAudio"]),
        .library(name: "MeetingSpeech", targets: ["MeetingSpeech"]),
        .library(name: "MeetingTranscript", targets: ["MeetingTranscript"]),
    ],
    targets: [
        .target(name: "MeetingAudio"),
        .target(name: "MeetingSpeech"),
        .target(name: "MeetingTranscript"),
        .executableTarget(
            name: "MeetingAssistantCLI",
            dependencies: ["MeetingAudio", "MeetingSpeech", "MeetingTranscript"]
        ),
        .executableTarget(
            name: "MeetingAssistantSelfTest",
            dependencies: ["MeetingAudio", "MeetingSpeech", "MeetingTranscript"]
        ),
    ]
)
