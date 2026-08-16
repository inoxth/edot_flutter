import 'dart:async';

import 'package:flutter/material.dart';

/// Shown when the env file carries no `EDOT_SERVER_URL`, so the Agent is never started.
///
/// Every flavor app falls back to this when [loadDemoConfig] reports missing config.
class MissingEnvApp extends StatelessWidget {
  const MissingEnvApp({required this.reason, super.key});

  final String reason;

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'EDOT Flutter example',
    home: Scaffold(
      appBar: AppBar(title: const Text('EDOT example — configuration needed')),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(reason, textAlign: TextAlign.center),
        ),
      ),
    ),
  );
}

/// A padded [ListView] the demo screens lay their cards out in.
class DemoActionList extends StatelessWidget {
  const DemoActionList({required this.children, super.key});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) =>
      ListView(padding: const EdgeInsets.all(16), children: children);
}

/// A pushed demo screen: an app bar titled [title] over a [DemoActionList].
class DemoScreen extends StatelessWidget {
  const DemoScreen({required this.title, required this.children, super.key});

  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: Text(title)),
    body: DemoActionList(children: children),
  );
}

/// A tappable card that runs one demo action.
class DemoActionTile extends StatelessWidget {
  const DemoActionTile(
    this.label,
    this.description,
    this.onPressed, {
    super.key,
  });

  final String label;
  final String description;
  final FutureOr<void> Function() onPressed;

  @override
  Widget build(BuildContext context) => Card(
    child: ListTile(
      title: Text(label),
      subtitle: Text(description),
      trailing: const Icon(Icons.play_arrow),
      onTap: () => onPressed(),
    ),
  );
}

/// A small explanatory paragraph above a group of actions.
class DemoNote extends StatelessWidget {
  const DemoNote(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 12),
    child: Text(text, style: Theme.of(context).textTheme.bodySmall),
  );
}

/// A rolling, newest-first record of what the demo has done.
class DemoLog extends ChangeNotifier {
  DemoLog._();

  static const _limit = 20;
  final List<String> _entries = [];

  List<String> get entries => List.unmodifiable(_entries);

  void add(String message) {
    _entries.insert(0, message);
    if (_entries.length > _limit) _entries.removeLast();
    notifyListeners();
  }
}

/// App-wide demo event log.
///
/// A singleton so a pushed demo screen and the Home tab share one list without
/// threading it through every route. Global mutable state is a smell in real
/// code; here it keeps the demo readable and is the only place it appears.
final demoLog = DemoLog._();

/// Renders [demoLog], newest first.
class DemoLogView extends StatelessWidget {
  const DemoLogView({super.key});

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: demoLog,
    builder: (context, _) {
      final entries = demoLog.entries;
      final style = Theme.of(context).textTheme.bodySmall;
      if (entries.isEmpty) {
        return Text('No events yet - run an action.', style: style);
      }
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final entry in entries)
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Text('• $entry', style: style),
            ),
        ],
      );
    },
  );
}
