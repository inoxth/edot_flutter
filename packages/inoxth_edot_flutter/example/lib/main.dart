import 'package:flutter/material.dart';
import 'package:inoxth_edot_flutter/inoxth_edot_flutter.dart';

/// Example app for `inoxth_edot_flutter`.
///
/// Today it only proves the Plugin registers on both platforms and that the
/// pinned Agents link. Each later ticket adds the behaviour it introduces here,
/// so this app ends up demonstrating every documented feature.
void main() {
  runApp(const ExampleApp());
}

class ExampleApp extends StatelessWidget {
  const ExampleApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'EDOT Flutter example',
      home: Scaffold(
        appBar: AppBar(title: const Text('EDOT Flutter example')),
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Text(
                  'Plugin registered',
                  style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 12),
                Text('Channel: $edotChannelName'),
                const SizedBox(height: 24),
                const Text(
                  'No telemetry yet — Agent initialisation lands in the '
                  'tracer-bullet ticket.',
                  textAlign: TextAlign.center,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
