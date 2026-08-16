# inoxth_edot_flutter examples

Two steps: start the plugin, then hand `MaterialApp` the observer. Everything after that -
spans, logs, metrics, traced requests - is tagged with the screen it came from without any
further wiring.

```dart
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:inoxth_edot_flutter/inoxth_edot_flutter.dart';

// Wraps the client the app already uses; a plain one here.
final client = EdotHttpClient(http.Client());

Future<void> main() async {
  await Edot.start(
    EdotConfig(
      serviceName: 'my-app',
      serviceVersion: '1.0.0',
      deploymentEnvironment: 'development',
      serverUrl: 'http://localhost:4318',
      // Every request through the client above is traced. This decides which of
      // them also carry W3C Trace Context, so the service on the other end can
      // join the trace.
      tracePropagationTargets: [RegExp(r'^https://api\.example\.com')],
    ),
  );

  runApp(const ExampleApp());
}

class ExampleApp extends StatelessWidget {
  const ExampleApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      // Screen Spans, and the screen attributes every other signal is tagged
      // with, come from this observer.
      navigatorObservers: [EdotNavigatorObserver()],
      home: Scaffold(
        body: Center(
          child: ElevatedButton(
            onPressed: () async {
              Edot.log(EdotSeverity.info, 'Order list opened');
              await client.get(Uri.https('api.example.com', '/orders'));
            },
            child: const Text('Send a traced request'),
          ),
        ),
      ),
    );
  }
}
```

That button produces a log record and one client span named `GET`, both carrying the Elastic
Mobile Attribute Set and the attributes of whichever screen was visible at the time.

**`package:http` is your dependency.** `EdotHttpClient` wraps an `http.Client`, so add `http`
to your own `pubspec.yaml` to construct one. If the app uses Dio instead, add
[`inoxth_edot_flutter_dio`](https://pub.dev/packages/inoxth_edot_flutter_dio) and skip this.

**Nothing emitted before `Edot.start` is lost.** It is held in a bounded queue and replayed
once the Agent is up, so instrumentation does not have to wait for startup to finish.

## The example apps

Three of them, each a complete Flutter app that integrates the plugin a different way. Pick the
one whose navigation matches your app - they share the same demo screens through the `shared`
package, so the only real difference between them is how each wires `EdotNavigatorObserver`.

| Flavor | Navigation | What to copy from it |
|---|---|---|
| [`basic`](basic) | None - one screen | The smallest integration: start the Agent from `env/local.env`, then emit a span, a metric, a log, a reported error, and read the Session identifier. No navigation, no network. |
| [`navigator`](navigator) | Flutter `Navigator` (named routes) | The reference flavor. Home / Demos / Settings, a screen per telemetry area (logs at every severity, all three network paths, an interaction span, an in-page views screen tracked by `EdotViewObserver`, more), a parametric route that normalizes its Screen Name, and `EdotNavigatorObserver` on `MaterialApp.navigatorObservers`. Also hosts the Seam 2 tests. |
| [`go_router`](go_router) | [`go_router`](https://pub.dev/packages/go_router) | The same demo routed with `go_router` - `EdotNavigatorObserver` via `GoRouter.observers`, `context.push` to open a screen. |

`shared` is not a flavor: it holds the demo screens and primitives the three apps reuse, which is
why each `main.dart` reads as little more than the navigation wiring.

**Reading these from pub.dev?** They ship in the published package, but they will not run from it.
Each flavor depends on `shared` through the pub workspace, and the workspace root is not part of the
tarball - so extracted on its own, none of them resolves. Clone the repository to run them; from
pub.dev they are worked examples to read.

## Common setup

Every flavor reads its configuration from `env/local.env` (via `flutter_dotenv`). Copy the
template, point it at your collector, and run:

```bash
cd basic            # or navigator, or go_router
cp env/local.env.example env/local.env
flutter run
```

**A fresh clone builds and runs without this step.** Each flavor declares the `env/` directory as
an asset rather than the file, so nothing is missing before you copy anything - the app simply
finds no configuration and shows its "configuration needed" screen instead of starting the Agent.
Copy the template when you want it to actually export.

Set `EDOT_SERVER_URL` in `env/local.env` to your collector's OTLP/HTTP endpoint. On an Android
emulator the collector on your host machine is usually `http://10.0.2.2:4318`. Beyond the server
URL and identity fields, the file can also set the OTLP transport (`EDOT_EXPORT_PROTOCOL`, `http`
or `grpc`) and the session sampling rate (`EDOT_SESSION_SAMPLING_RATE`, 0.0-1.0). See each
flavor's `env/local.env.example` for the full set of keys.

`env/local.env` is gitignored; `env/local.env.example` is tracked. Point the former at a real
collector without worrying about committing it.
