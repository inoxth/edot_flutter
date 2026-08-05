import 'dart:io';

import 'package:inoxth_edot_flutter/inoxth_edot_flutter.dart';

/// Flushing for Seam 2: drains the Plugin's buffers *and* waits out whatever the Agent
/// puts between that flush and the wire.
///
/// Every device half needs this, because `Edot.flush()` does not promise delivery
/// (ADR-0011) and both pinned Agents interpose something of their own. The two
/// mechanisms differ, and so does the order they have to be handled in — which is why
/// this is a function rather than a shared constant.
///
/// **Android — the exporter gate, before the flush.** `agent-sdk` 1.1.0 wraps every
/// exporter in a `GateSpanExporter`/`GateLogRecordExporter`/`GateMetricExporter` that
/// enqueues rather than exports until its latches open, and *reports success while doing
/// so*. The gate opens when every latch is released or after
/// `ExporterGateManager`'s timeout, which defaults to **3 seconds** from initialisation.
/// So a flush inside that window returns successfully with the telemetry still in the
/// queue, and a test that then ends loses it when the process dies. Waiting first means
/// the gate is already open when the flush happens, so the flush goes to the network.
///
/// **iOS — the persistence worker, after the flush.** There the flush reaches an on-disk
/// buffer that cannot be disabled, and a worker uploads on its own schedule: a file stays
/// writable for up to 4.75s, is not readable until 5.25s old, and exports re-schedule on a
/// ~5s delay. Worst case is around 11s.
///
/// Both numbers are the Agents', not guesses. They are the only reason a Seam 2 device
/// half has to wait at all, and a wait chosen by trial would drift the moment either
/// Agent's defaults changed.
Future<void> flushUntilAssertable() async {
  if (Platform.isAndroid) {
    await Future<void>.delayed(androidExportGateWindow);
    await Edot.flush();
    return;
  }

  await Edot.flush();
  await Future<void>.delayed(iosPersistenceUploadWindow);
}

/// How long the Android exporter gate can hold telemetry after initialisation.
///
/// The Agent's own default is 3 seconds; the margin covers the gate's timeout task being
/// scheduled slightly after our `initialize` call returns, and the release of the queue to
/// the real exporter afterwards.
const Duration androidExportGateWindow = Duration(seconds: 5);

/// How long the iOS persistence worker can hold telemetry after a flush.
///
/// Around 11 seconds worst case, per the file ages and export delay above; 15 leaves
/// margin without making the tier slow enough to be skipped.
const Duration iosPersistenceUploadWindow = Duration(seconds: 15);
