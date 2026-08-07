# inoxth_edot_flutter examples

Three example apps, each a complete Flutter app that integrates the plugin a different way.
Pick the one whose navigation matches your app - they share the same demo screens through the
`shared` package, so the only real difference between them is how each wires
`EdotNavigatorObserver`.

| Flavor | Navigation | What to copy from it |
|---|---|---|
| [`basic`](basic) | None - one screen | The smallest integration: start the Agent from `.env`, then emit a span, a metric, a log, a reported error, and read the Session identifier. No navigation, no network. |
| [`navigator`](navigator) | Flutter `Navigator` (named routes) | The reference flavor. Home / Demos / Settings, a screen per telemetry area (logs at every severity, all three network paths, an interaction span, an in-page views screen tracked by `EdotViewObserver`, more), a parametric route that normalizes its Screen Name, and `EdotNavigatorObserver` on `MaterialApp.navigatorObservers`. Also hosts the Seam 2 tests. |
| [`go_router`](go_router) | [`go_router`](https://pub.dev/packages/go_router) | The same demo routed with `go_router` - `EdotNavigatorObserver` via `GoRouter.observers`, `context.push` to open a screen. |

`shared` is not a flavor: it holds the demo screens and primitives the three apps reuse, which is
why each `main.dart` reads as little more than the navigation wiring.

## Common setup

Every flavor reads its configuration from a `.env` file (via `flutter_dotenv`). Copy the template,
point it at your collector, and run:

```bash
cd basic            # or navigator, or go_router
cp .env.example .env
flutter run
```

Set `EDOT_SERVER_URL` in `.env` to your collector's OTLP/HTTP endpoint. On an Android emulator the
collector on your host machine is usually `http://10.0.2.2:4318`. With no `EDOT_SERVER_URL` set, an
app shows a "Missing .env" screen instead of starting the Agent, so a fresh clone runs without
configuration. Beyond the server URL and identity fields, `.env` can also set the OTLP transport
(`EDOT_EXPORT_PROTOCOL`, `http` or `grpc`) and the session sampling rate
(`EDOT_SESSION_SAMPLING_RATE`, 0.0-1.0). See each flavor's `.env.example` for the full set of keys.
