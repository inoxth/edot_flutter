/// Shared contract between the two halves of the disk-buffering test.
///
/// Deliberately free of Flutter imports: the host half runs under plain `dart run`, where
/// `dart:ui` does not exist.
///
/// **Android only**, and every timing below is the Android Agent's. iOS buffers to disk too and
/// cannot be told not to, but there delivery is driven by a persistence worker that backs off to
/// a 20-second ceiling on repeated failure and that `flush` cannot drive (ADR-0011) — runs there
/// had the same case deliver everything and then nothing, so an iOS assertion would be measuring
/// that timer's luck. The device half refuses to run outside Android rather than reporting it.
///
/// **Why this suite exists separately from the platform-configuration one.** That suite
/// switches disk buffering off in every case, because with it on nothing arrives inside its
/// window and "nothing arrived" is its assertion. This suite asserts the opposite thing —
/// that telemetry produced with no collector to reach arrives once there is one — so it needs
/// the buffer on, an unreachable collector, and a window long enough for a late delivery.
///
/// **Why the collector returns mid-launch, rather than between launches.** The obvious shape
/// is to emit in one app run and drain in the next, which is also the real scenario. It cannot
/// work here: `flutter test` uninstalls the app when the run ends, and the Agent's buffer lives
/// in that app's data directory, so it is deleted along with everything else. The whole
/// sequence therefore has to happen inside one process.
///
/// **Why the device signals the host.** The host has to bring the collector back *after* the
/// device has emitted offline, and it has no other way to know when that is — the build,
/// install and launch ahead of it take an unpredictable amount of time. Waiting a fixed
/// interval instead would race: too short and the telemetry was never really offline, which
/// would turn "buffered telemetry arrived" into the far weaker "telemetry arrived". The signal
/// removes the guess, and the suite still asserts the offline period was real.
///
/// **The timings below are the pinned Agent's, read from its bytecode** (recorded on the
/// ticket). `agent-sdk` 1.1.0 does not use the upstream defaults: it builds its own
/// `StorageConfiguration` with a 2-second write age and a **4-second minimum read age**, and
/// polls for delivery every second. A batch is ineligible to be read for its first 4 seconds,
/// and a delivery that fails is kept — `FromDiskExporterImpl` returns `TRY_LATER`, which
/// leaves the batch on disk — so a later poll picks it up. That retention is the behaviour
/// this suite exists to prove.
///
/// **What disk buffering actually adds.** Not "telemetry survives an outage" on its own — the
/// OTLP exporter already retries in memory for about 8 seconds, so a brief outage is survived
/// with the buffer switched off. What the buffer adds is durability past that budget. The
/// outage here is therefore sized to defeat the retry, or the two cases would be
/// indistinguishable; see [offlineWindow].
///
/// One bound it does **not** exercise: `maxFileAgeForReadMillis` is left at upstream's
/// **18 hours**, so buffered telemetry older than that is discarded rather than delivered. No
/// test can wait that out; it is documented for integrators instead.
library;

/// Selects the case, passed to the device half as `--dart-define`.
const String caseVariable = 'EDOT_BUFFERING';

/// One per app launch, each with the service name its telemetry arrives under.
///
/// Separate launches because `Edot.start` may be called only once per process, and separate
/// service names so the host half can tell one launch's telemetry from the other's.
enum BufferingCase {
  /// Buffering **on**. The probe emitted while the collector was down must arrive once it
  /// is back.
  buffered('buffered', 'edot-flutter-seam2-buffered'),

  /// Buffering **off**. The same probe must be lost.
  ///
  /// What keeps the case above from being vacuous: it is the comparison that shows the buffer
  /// is what delivered, rather than something else in the pipeline.
  unbuffered('unbuffered', 'edot-flutter-seam2-unbuffered');

  const BufferingCase(this.define, this.serviceName);

  /// Value passed as `--dart-define=EDOT_BUFFERING=<define>`.
  final String define;

  /// `service.name` this case's telemetry arrives under.
  final String serviceName;
}

/// Emitted while the collector is unreachable. The span the suite is about.
const String probeSpanName = 'disk-buffering-probe';

/// Emitted after the collector is back, to prove it was reachable by then.
///
/// This is what makes the negative case mean something: without it, a probe that never arrived
/// could equally be one the collector was never able to receive, and "lost because buffering
/// was off" would be indistinguishable from "lost because the collector stayed down".
const String reachableMarkerSpanName = 'disk-buffering-reachable-marker';

/// Which platform ran. What `diskBufferingEnabled: false` means differs by platform
/// (ADR-0001) and the host half has no other way to know.
const String platformAttribute = 'test.platform';

/// Port the host half listens on for the device's "I have emitted offline" signal.
///
/// Not the collector's port, and nothing else binds it. The device reaches it at the same host
/// it reaches the collector at, so the emulator's alias applies here too.
const int signalPort = 4319;

/// How long the device waits after signalling, before emitting the reachable marker.
///
/// Covers the host bringing the collector back up: a compose start plus a readiness check.
const Duration collectorReturnWindow = Duration(seconds: 20);

/// How long the host waits after a launch ends, before stopping the collector or reading it.
///
/// The collector holds received telemetry for up to its own `flush_interval` — one second —
/// before it reaches the file, and this suite stops the container between cases. Without this
/// pause the last arrivals of a case are lost to the shutdown, and reading straight after the
/// final launch misses them the same way.
///
/// This was a real fault, not a precaution: it made exactly one of the two cases fail per run,
/// alternating between them, which reads like a platform quirk rather than a race in the
/// harness.
const Duration collectorFlushSettle = Duration(seconds: 4);

/// How long the device stays alive after that, for the Agent's drain job to deliver.
///
/// The Android Agent polls every second and its batch becomes readable 4 seconds after being
/// written, so this is many times what delivery needs. Deliberately so: a failure here should
/// mean delivery did not happen, never that the suite was impatient.
///
/// It is also what iOS would need much more of — its persistence worker backs off to a
/// 20-second ceiling between attempts — which is one reason this suite does not run there.
const Duration drainWindow = Duration(seconds: 30);

/// How long the collector stays unreachable after the telemetry is produced.
///
/// **This has to outlast the OTLP exporter's own retry, or the suite proves nothing.** The
/// pinned `opentelemetry-sdk-common` 1.51.0 retries a failed export 5 times with backoffs of
/// 1s, 1.5s, 2.25s and 3.375s — roughly 8 seconds of trying, in memory, with no disk buffer
/// involved. A shorter outage than that is survived by *any* configuration, which is exactly
/// what an earlier version of this suite measured: the case with buffering **off** delivered
/// its span too, and the difference the suite exists to demonstrate was invisible.
///
/// So the outage is deliberately far longer than the retry budget. What disk buffering adds is
/// durability beyond that budget, and this is the window in which that becomes the only
/// mechanism that can still deliver.
///
/// It also comfortably covers the buffer's own 2-second write window, so the batch on disk is a
/// complete file rather than one still being appended to.
const Duration offlineWindow = Duration(seconds: 45);
