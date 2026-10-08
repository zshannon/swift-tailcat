// swift-tools-version: 6.4
import Foundation
import PackageDescription

// Maintainer validation opts into the ignored, verified local build explicitly.
let tailcatCore: Target = ProcessInfo.processInfo.environment["TAILCAT_LOCAL_ARTIFACT"] == "1"
    ? .binaryTarget(name: "TailcatCore", path: "Artifacts/TailcatCore.xcframework.zip")
    : .binaryTarget(name: "TailcatCore", url: "https://github.com/zshannon/swift-tailcat/releases/download/v0.0.1/TailcatCore.xcframework.zip", checksum: "313571de2f27aa8a7e6f071bf9b748b1f557c179d9ac4f363888d0cd8f5cf687")

let package = Package(
    name: "swift-tailcat",
    platforms: [.iOS(.v16), .macOS(.v13)],
    products: [.library(name: "Tailcat", targets: ["Tailcat"])],
    dependencies: [.package(url: "https://github.com/pointfreeco/swift-dependencies", exact: "1.17.1"), .package(url: "https://github.com/pointfreeco/swift-issue-reporting", exact: "2.1.1")],
    targets: [
        .target(name: "Tailcat", dependencies: ["TailcatCore", .product(name: "Dependencies", package: "swift-dependencies"), .product(name: "IssueReporting", package: "swift-issue-reporting")]),
        tailcatCore,
        .testTarget(name: "TailcatTests", dependencies: ["Tailcat", .product(name: "Dependencies", package: "swift-dependencies")])
    ],
    swiftLanguageModes: [.v6]
)
