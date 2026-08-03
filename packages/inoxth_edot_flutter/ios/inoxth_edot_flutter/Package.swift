// swift-tools-version: 5.9
// Swift 5.9 matches the React Native SDK's iOS toolchain floor (Fleet Alignment).

import PackageDescription

let package = Package(
    name: "inoxth_edot_flutter",
    platforms: [
        // iOS 15.6 is a hard requirement. apm-agent-ios raised its floor to
        // iOS 16 in 1.3.0, which is why the Agent is pinned to 1.2.1 (ADR-0001).
        .iOS("15.6")
    ],
    products: [
        .library(name: "inoxth-edot-flutter", targets: ["inoxth_edot_flutter"])
    ],
    dependencies: [
        .package(name: "FlutterFramework", path: "../FlutterFramework"),

        // Pinned exactly per ADR-0001. Do not widen these to `from:` — a minor
        // bump raises the iOS floor above 15.6 and silently breaks the platform
        // requirement this package exists to satisfy.
        .package(
            url: "https://github.com/elastic/apm-agent-ios.git",
            exact: "1.2.1"
        ),
        // apm-agent-ios 1.2.1 itself pins this exact version. Declared here too
        // so the pin is explicit and enforced at resolution rather than implied.
        .package(
            url: "https://github.com/open-telemetry/opentelemetry-swift.git",
            exact: "1.13.0"
        )
    ],
    targets: [
        .target(
            name: "inoxth_edot_flutter",
            dependencies: [
                .product(name: "FlutterFramework", package: "FlutterFramework"),
                .product(name: "ElasticApm", package: "apm-agent-ios"),
                .product(name: "OpenTelemetryApi", package: "opentelemetry-swift"),
                .product(name: "OpenTelemetrySdk", package: "opentelemetry-swift")
            ],
            resources: [
                // Uncomment once the Plugin uses a required-reason API. It does not yet.
                // .process("PrivacyInfo.xcprivacy"),
            ]
        )
    ]
)
