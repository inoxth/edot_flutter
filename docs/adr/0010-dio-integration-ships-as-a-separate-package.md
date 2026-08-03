# The Dio integration ships as a separate package

Status: accepted

## Context

The Plugin must trace requests made through both `package:http` and `dio`. Shipping a Dio interceptor
inside the core package means depending on `dio`, and **Dart has no optional dependencies** — so every
consumer would inherit the constraint whether or not they use Dio. When Dio ships a major version,
those apps are blocked until we publish a new release.

`package:http` is a different case: it is published by dart.dev, is small, and is near-universal.

## Decision

A melos monorepo publishing two packages:

- **`inoxth_edot_flutter`** — Dart core, both native implementations, and the `package:http` wrapper.
- **`inoxth_edot_flutter_dio`** — the Dio interceptor only.

No federated platform-interface split. EDOT exists only for iOS and Android and we own both
implementations, so a platform-interface package plus per-platform packages would add three packages
and buy nothing — that structure exists for plugins inviting third-party platform implementations.

Naming: pub.dev has no scoped packages, so the React Native SDK's `@inoxth/` scope has no direct
equivalent. Organisation identity comes from the `inoxth_` name prefix plus a verified publisher.

## Consequences

- Dio users add two dependencies. Accepted, in exchange for never blocking a consumer's Dio upgrade.
- Do not merge the Dio interceptor into core "for convenience" — that reintroduces the constraint problem this ADR exists to avoid.
- Navigation needs no third-party dependency: `Navigator` is first-party, and GoRouter is supported through a screen-name extractor callback rather than a dependency, since Dart has no structural typing and cannot duck-type an external library the way the React Native SDK does for its navigators.
