import 'package:flutter/material.dart';
import 'package:inoxth_edot_flutter/inoxth_edot_flutter.dart';

import 'demo_destination.dart';
import 'demo_widgets.dart';

/// The shared app shell: Home / Demos / Settings bottom tabs.
///
/// Both flavor apps mount this at their root route. The tabs switch in place - a tab
/// switch pushes no route (ADR-0004), so the shell sets the Active View itself. Opening
/// a demo, by contrast, goes through [onOpenDemo] so the flavor's own router pushes a
/// real route the `EdotNavigatorObserver` turns into a Screen Span.
class DemoHome extends StatefulWidget {
  const DemoHome({required this.config, required this.onOpenDemo, super.key});

  final EdotConfig config;
  final Future<void> Function(BuildContext context, DemoDestination destination)
  onOpenDemo;

  @override
  State<DemoHome> createState() => _DemoHomeState();
}

class _DemoHomeState extends State<DemoHome> {
  static const _tabs = ['Home', 'Demos', 'Settings'];
  int _tab = 0;

  @override
  void initState() {
    super.initState();
    Edot.setActiveView(_tabs[_tab]);
  }

  void _selectTab(int index) {
    Edot.setActiveView(_tabs[index]);
    setState(() => _tab = index);
  }

  Future<void> _openDemo(DemoDestination destination) async {
    await widget.onOpenDemo(context, destination);
    // The observer set the Active View back to the root route ('Home') as the demo
    // popped; re-assert the tab the user is actually looking at.
    if (mounted) Edot.setActiveView(_tabs[_tab]);
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: Text('EDOT example — ${_tabs[_tab]}')),
    body: switch (_tab) {
      0 => const _HomeTab(),
      1 => _DemosTab(onOpen: _openDemo),
      _ => _SettingsTab(config: widget.config),
    },
    bottomNavigationBar: NavigationBar(
      selectedIndex: _tab,
      onDestinationSelected: _selectTab,
      destinations: const [
        NavigationDestination(icon: Icon(Icons.home), label: 'Home'),
        NavigationDestination(icon: Icon(Icons.widgets), label: 'Demos'),
        NavigationDestination(icon: Icon(Icons.settings), label: 'Settings'),
      ],
    ),
  );
}

class _HomeTab extends StatefulWidget {
  const _HomeTab();

  @override
  State<_HomeTab> createState() => _HomeTabState();
}

class _HomeTabState extends State<_HomeTab> {
  String _sessionId = 'not read yet';

  Future<void> _readSessionId() async {
    final id = await Edot.currentSessionId();
    setState(() {
      // Empty on Android, always: its Agent exposes the session manager only as internal
      // API (ADR-0001). A support screen has to handle that rather than display it.
      _sessionId = id.isEmpty
          ? 'empty — expected on Android, and before start'
          : id;
    });
  }

  @override
  Widget build(BuildContext context) => DemoActionList(
    children: [
      DemoNote(
        'The Agent is ${Edot.isStarted ? 'started' : 'not started'}. Every signal carries '
        'the Active View - switch tabs, or open a demo, and watch screen.name change on '
        'what you emit next.',
      ),
      DemoActionTile('Read Session identifier', _sessionId, _readSessionId),
      DemoActionTile(
        'Flush',
        "Drains the Plugin's buffers. Does NOT promise delivery (ADR-0011).",
        () async {
          await Edot.flush();
          demoLog.add('Flushed the Plugin buffers');
        },
      ),
      const Padding(
        padding: EdgeInsets.only(top: 8, bottom: 8),
        child: Text('Recent events'),
      ),
      const DemoLogView(),
    ],
  );
}

class _DemosTab extends StatelessWidget {
  const _DemosTab({required this.onOpen});

  final void Function(DemoDestination destination) onOpen;

  @override
  Widget build(BuildContext context) => DemoActionList(
    children: [
      const DemoNote(
        'Each demo is a real pushed route, so opening one produces a Screen Span and '
        'moves the Active View to that screen (ADR-0004). Go back and the Active View '
        'returns to this tab.',
      ),
      for (final destination in DemoDestination.values)
        Card(
          child: ListTile(
            leading: Icon(destination.icon),
            title: Text(destination.title),
            subtitle: Text(destination.summary),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => onOpen(destination),
          ),
        ),
    ],
  );
}

class _SettingsTab extends StatefulWidget {
  const _SettingsTab({required this.config});

  final EdotConfig config;

  @override
  State<_SettingsTab> createState() => _SettingsTabState();
}

class _SettingsTabState extends State<_SettingsTab> {
  static const _meanings = {
    EdotTrackingConsent.granted: 'Emitting. The user said yes.',
    EdotTrackingConsent.notGranted: 'Silent. The user said no.',
    EdotTrackingConsent.pending: 'Silent. We have not asked yet.',
  };

  static String _authLabel(EdotAuth auth) => switch (auth) {
    EdotSecretTokenAuth() => 'secret token (****)',
    EdotApiKeyAuth() => 'API key (****)',
    EdotNoAuth() => 'none',
  };

  @override
  Widget build(BuildContext context) {
    final config = widget.config;
    return DemoActionList(
      children: [
        const DemoNote('Values the app started with, read from .env.'),
        _ConfigRow('Service name', config.serviceName),
        _ConfigRow('Service version', config.serviceVersion),
        _ConfigRow('Environment', config.deploymentEnvironment),
        _ConfigRow('Server URL', config.serverUrl),
        _ConfigRow('Auth', _authLabel(config.auth)),
        const Divider(height: 32),
        const DemoNote(
          'Tracking Consent takes effect on the very next emission, in either direction, '
          'with no restart. Telemetry produced while consent is withheld is discarded '
          'rather than held - granting later does not release it (ADR-0015).',
        ),
        RadioGroup<EdotTrackingConsent>(
          groupValue: Edot.trackingConsent,
          onChanged: (value) {
            if (value == null) return;
            setState(() => Edot.setTrackingConsent(value));
          },
          child: Column(
            children: [
              for (final consent in EdotTrackingConsent.values)
                RadioListTile<EdotTrackingConsent>(
                  value: consent,
                  title: Text(consent.wireValue),
                  subtitle: Text(_meanings[consent]!),
                ),
            ],
          ),
        ),
      ],
    );
  }
}

class _ConfigRow extends StatelessWidget {
  const _ConfigRow(this.label, this.value);

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) => Card(
    child: ListTile(
      title: Text(label),
      subtitle: Text(value, style: const TextStyle(fontFamily: 'monospace')),
    ),
  );
}
