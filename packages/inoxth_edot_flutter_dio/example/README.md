# Example

Two lines: start the plugin, then add the interceptor to the `Dio` instance the app already
uses. There is nothing to configure on the interceptor itself.

```dart
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:inoxth_edot_flutter/inoxth_edot_flutter.dart';
import 'package:inoxth_edot_flutter_dio/inoxth_edot_flutter_dio.dart';

final dio = Dio()..interceptors.add(EdotDioInterceptor());

Future<void> main() async {
  await Edot.start(
    EdotConfig(
      serviceName: 'dio-example',
      serviceVersion: '1.0.0',
      deploymentEnvironment: 'development',
      serverUrl: 'http://localhost:4318',
      // Which requests carry W3C Trace Context, and which are never traced at
      // all, are decided here rather than on the interceptor.
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
      // Screen Spans, and the screen attributes every request span is tagged
      // with, come from this observer.
      navigatorObservers: [EdotNavigatorObserver()],
      home: Scaffold(
        body: Center(
          child: ElevatedButton(
            onPressed: () => dio.get<void>('https://api.example.com/orders'),
            child: const Text('Send a traced request'),
          ),
        ),
      ),
    );
  }
}
```

That request becomes one client span named `GET`, carrying the Elastic Mobile Attribute Set and
the attributes of whichever screen was visible when it was sent.

## Two things worth knowing

**Add the interceptor last** if the app has others that rewrite requests. Dio runs interceptors
in the order they were added, so a URL rewritten by an interceptor added *after* this one is
recorded as it was *before* the rewrite.

**One instance serves many `Dio` instances.** The interceptor holds no state - a request's span
travels with the request - so there is no reason to construct more than one.

## A runnable app

This page is a snippet, not a project. For an app you can actually run, see
[`example/navigator`](https://github.com/inoxth/edot_flutter/tree/main/packages/inoxth_edot_flutter/example/navigator)
in the repository, whose Network tab exercises this interceptor alongside the plugin's other two
network paths.
