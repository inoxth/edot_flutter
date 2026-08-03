# Distribute the iOS platform side via Swift Package Manager only

Status: accepted

## Context

`apm-agent-ios` has no podspec anywhere in its repository and is not published to CocoaPods trunk.
It is SPM-only. Upstream `opentelemetry-swift` publishes podspecs for peripheral components only —
podspecs for the core Api and Sdk targets do not exist.

Flutter's own guidance says plugins "should support both Swift Package Manager and CocoaPods until
further notice". However SPM is enabled by default from Flutter 3.44, and CocoaPods becomes read-only
on 2 December 2026.

The organisation's React Native SDK ships a real podspec, but only because React Native provides an
`spm_dependency` helper (RN 0.75+) that mutates the Pods project to add an SPM package reference.
Flutter has no equivalent.

## Decision

Ship `Package.swift` and no podspec. Require Flutter 3.44+, where SPM is default-on. State the
floors — iOS 15.6, Android minSdk 24, Flutter 3.44+, SPM required — at the top of the README and in
the pubspec.

## Considered options

- **Author podspecs for the upstream Swift dependencies.** Rejected — makes us the de-facto maintainer of podspecs for `apm-agent-ios` and for `opentelemetry-swift`'s core targets, which upstream deliberately does not publish, for a toolchain going read-only.
- **Publish a pre-built XCFramework with a podspec.** Rejected — requires rebuilding per Agent release and per Xcode/Swift version, satisfying Swift module stability for static Swift libraries, hosting the binary, and carrying the licence and NOTICE obligations of every bundled dependency.

## Consequences

- Apps that have run `flutter config --no-enable-swift-package-manager`, or whose Xcode project has not migrated, cannot use the Plugin.
- Flutter's both-toolchains guidance is knowingly not followed. Revisit only if the CocoaPods sunset slips materially.
