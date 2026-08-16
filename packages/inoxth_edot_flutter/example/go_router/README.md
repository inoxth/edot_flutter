# inoxth_edot_flutter example - go_router flavor

The same demo as the `navigator` flavor, routed with [`go_router`](https://pub.dev/packages/go_router)
instead of Flutter's built-in `Navigator`. Every screen comes from the shared package;
`lib/main.dart` differs from the navigator flavor only in navigation wiring - a `GoRouter`
whose `observers` include the same `EdotNavigatorObserver`, and `context.push` to open a
demo.

Because the screens are shared, it demonstrates the same two-part screen tracking: navigation
Screen Spans through `EdotNavigatorObserver` in the router's `observers`, and automatic in-page
view tracking through `EdotViewObserver` in the shared shell - the Home / Demos / Settings bottom
tabs and the In-page views screen - with no go_router-specific code. Returning from a pushed demo
lands the Active View back on the tab you were on, exactly as in the navigator flavor.

## Run

```bash
cp env/local.env.example env/local.env   # then point EDOT_SERVER_URL at your collector
flutter run
```

With no `EDOT_SERVER_URL` the app shows its "configuration needed" screen instead of starting
the Agent.
