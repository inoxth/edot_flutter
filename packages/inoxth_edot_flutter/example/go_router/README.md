# inoxth_edot_flutter example - go_router flavor

The same demo as the `navigator` flavor, routed with [`go_router`](https://pub.dev/packages/go_router)
instead of Flutter's built-in `Navigator`. Every screen comes from the shared package;
`lib/main.dart` differs from the navigator flavor only in navigation wiring - a `GoRouter`
whose `observers` include the same `EdotNavigatorObserver`, and `context.push` to open a
demo.

## Run

```bash
cp .env.example .env        # then point EDOT_SERVER_URL at your collector
flutter run
```

With no `EDOT_SERVER_URL` the app shows a "Missing .env" screen instead of starting
the Agent.
