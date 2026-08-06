# inoxth_edot_flutter example - basic flavor

The smallest integration: one scrollable screen, no navigation and no network. It
starts the Agent from a `.env` file and emits a span, a metric, a log, a reported
error, and shows the Session identifier, plus an `EdotErrorBoundary`.

## Run

```bash
cp .env.example .env        # then point EDOT_SERVER_URL at your collector
flutter run
```

With no `EDOT_SERVER_URL` the app shows a "Missing .env" screen instead of starting
the Agent. See the `navigator` and `go_router` flavors for screen tracking and request
tracing.
