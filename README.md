# inoxth_edot_flutter

Flutter plugin that surfaces the Elastic Distribution of OpenTelemetry (EDOT)
mobile Agents to Dart, so a Flutter app reports into Elastic the same way a native
app does.

**Using the plugin in an app?** Read
[`packages/inoxth_edot_flutter/README.md`](packages/inoxth_edot_flutter/README.md) — the setup
guide, the recipes and the complete list of deliberate limitations live there.

## Requirements

| | Minimum |
|---|---|
| iOS | **15.6** — Swift Package Manager required, no CocoaPods support |
| Android | **API 24** (compileSdk 36) |
| Flutter | **3.44** — SPM is default-on from this version |

## Packages

Two installable packages; each has its own README.

| Package | README | Purpose |
|---|---|---|
| `inoxth_edot_flutter` | [README](packages/inoxth_edot_flutter/README.md) | Core: Dart API, both native implementations, `package:http` tracing |
| `inoxth_edot_flutter_dio` | [README](packages/inoxth_edot_flutter_dio/README.md) | Dio interceptor. Separate because Dart has no optional dependencies |

The repository also holds test infrastructure (`edot_collector_harness`) and the example app —
[`CONTRIBUTING.md`](CONTRIBUTING.md) maps the full layout.

## Contributing

**Working *on* the plugin?** [`CONTRIBUTING.md`](CONTRIBUTING.md) covers the toolchain, the two test seams and the change workflow.
