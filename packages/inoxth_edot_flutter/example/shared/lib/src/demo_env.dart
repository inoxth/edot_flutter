import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:inoxth_edot_flutter/inoxth_edot_flutter.dart';

import 'demo_config.dart';

/// Loads a flavor app's `.env` and turns it into a [DemoConfigResult].
///
/// This is the edge that touches the file system, keeping [DemoConfig.fromEnv]
/// pure. The `.env` must be declared as an asset in the calling app's pubspec.
/// `isOptional` means a stripped build - or a checkout where `.env` is empty -
/// degrades to the missing-config guard rather than throwing.
Future<DemoConfigResult> loadDemoConfig({
  String fileName = '.env',
  bool debug = false,
  bool traceAllHttpTraffic = false,
  EdotTrackingConsent trackingConsent = EdotTrackingConsent.granted,
}) async {
  await dotenv.load(fileName: fileName, isOptional: true);

  return DemoConfig.fromEnv(
    dotenv.env,
    debug: debug,
    traceAllHttpTraffic: traceAllHttpTraffic,
    trackingConsent: trackingConsent,
  );
}
