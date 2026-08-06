# inoxth_edot_flutter example - navigator flavor

The reference flavor: a multi-screen app routed with Flutter's built-in `Navigator` (named
routes). Home / Demos / Settings tabs, with a screen per telemetry area - network, tracing,
metrics, logs, and errors - reached through `EdotNavigatorObserver` on
`MaterialApp.navigatorObservers`, so each push produces a Screen Span and moves the Active View.
Between its screens it exercises every feature: manual spans, logs and metrics, all three network
paths, error capture and the boundary, navigation and tab tracking, the Tracking Consent states,
and the Session identifier.

This flavor is also the home of the **Seam 2** integration tests (`tool/verify_*.dart`); see
[`CONTRIBUTING.md`](../../../../CONTRIBUTING.md) for how to run them.

## Run

```bash
cp .env.example .env        # then point EDOT_SERVER_URL at your collector
flutter run
```

With no `EDOT_SERVER_URL` the app shows a "Missing .env" screen instead of starting the Agent.
