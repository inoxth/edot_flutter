# inoxth_edot_flutter example - navigator flavor

The reference flavor: a multi-screen app routed with Flutter's built-in `Navigator` (named
routes). Home / Demos / Settings tabs, with a screen per telemetry area - network, tracing,
metrics, logs, errors, interaction, and an in-page views screen - reached through
`EdotNavigatorObserver` on
`MaterialApp.navigatorObservers`, so each push produces a Screen Span and moves the Active View.
Between its screens it exercises every feature: manual spans, logs at every severity, all three
metric kinds, all three network paths (plus a failed and a batched-sequential request), error
capture and the boundary, navigation Screen Spans via `EdotNavigatorObserver` and automatic
in-page view tracking via `EdotViewObserver` (the Home / Demos / Settings bottom tabs, plus the
In-page views screen's own `TabController`), a parameterised `/orders/<id>` route that shows
Screen Name normalization, the Tracking Consent states, and the Session identifier. The
Settings tab echoes the config the app started with, including the OTLP transport and session
sampling rate read from `.env`.

This flavor is also the home of the **Seam 2** integration tests (`tool/verify_*.dart`); see
[`CONTRIBUTING.md`](../../../../CONTRIBUTING.md) for how to run them.

## Run

```bash
cp .env.example .env        # then point EDOT_SERVER_URL at your collector
flutter run
```

With no `EDOT_SERVER_URL` the app shows a "Missing .env" screen instead of starting the Agent.
Beyond the server URL, `.env` also sets the identity fields, auth, the OTLP transport
(`EDOT_EXPORT_PROTOCOL`) and the session sampling rate (`EDOT_SESSION_SAMPLING_RATE`) - see
`.env.example`.
