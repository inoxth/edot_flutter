import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:inoxth_edot_flutter/inoxth_edot_flutter.dart';

import 'demo_config.dart';

/// Loads a flavor app's env file and turns it into a [DemoConfigResult].
///
/// This is the edge that touches the file system, keeping [DemoConfig.fromEnv]
/// pure. The containing `env/` directory must be declared as an asset in the
/// calling app's pubspec; the file inside it is gitignored, so a fresh clone has
/// the directory but not the file. `isOptional` is what makes that survivable -
/// a checkout with no env file, like a stripped build, degrades to the
/// missing-config guard rather than throwing.
///
/// The default path is spelled once, here, rather than passed in by each flavor.
Future<DemoConfigResult> loadDemoConfig({
  String fileName = 'env/local.env',
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
