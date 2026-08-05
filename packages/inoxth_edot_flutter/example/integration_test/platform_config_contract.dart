/// Shared contract between the two halves of the platform-configuration test.
///
/// Deliberately free of Flutter imports: the host half runs under plain
/// `dart run`, where `dart:ui` does not exist.
///
/// **Why this suite runs the device half more than once.** `Edot.start` may be called only
/// once per process, so one configuration per run is the only way to compare them. Each run
/// uses a distinct service name, which lets a single collector hold all of their output and
/// the host half tell the runs apart — an absent export is the assertion for two of these
/// cases, and an absent export is exactly what a shared service name would make ambiguous.
///
/// **Disk buffering is not among the options this suite varies**, and is switched off in
/// every case. Its purpose is surviving an offline period, which this harness cannot create:
/// the collector is reached over loopback, so there is no connection to take away. Leaving it
/// on would also make every case silent within the window — `flush` fills the buffer and the
/// upload follows the Agent's own schedule (ADR-0011) — and "nothing arrived" is the
/// assertion for two of these cases, so it has to mean something. Seam 1 covers the option
/// reaching the Agent.
library;

/// Selects the configuration, passed to the device half as `--dart-define`.
const String caseVariable = 'EDOT_CASE';

/// One case per configuration, each with the service name its telemetry arrives under.
enum ConfigCase {
  /// Everything at its default. The baseline the other three are read against, and where
  /// the Session identifier is checked.
  normal('normal', 'edot-flutter-seam2-normal'),

  /// `disableAgent: true`. Nothing may arrive.
  disabled('disabled', 'edot-flutter-seam2-disabled'),

  /// `sessionSamplingRate: 0.0`. Nothing may arrive **on Android**.
  ///
  /// The pinned iOS Agent ignores the rate for a session that is already live (ADR-0001), so
  /// the host half reports what arrived there rather than asserting on it.
  sampledOut('sampled-out', 'edot-flutter-seam2-sampled-out'),

  /// Every iOS instrumentation toggle off. Telemetry the app produces itself must still
  /// arrive: these options govern what the Agent collects on its own, not whether the
  /// export pipeline works.
  instrumentationOff('instrumentation-off', 'edot-flutter-seam2-instr-off');

  const ConfigCase(this.define, this.serviceName);

  /// Value passed as `--dart-define=EDOT_CASE=<define>`.
  final String define;

  /// `service.name` this case's telemetry arrives under.
  final String serviceName;
}

/// Started by every case, so each one's presence or absence is asserted on the same shape.
const String probeSpanName = 'platform-config-probe';

/// The Session identifier the app read, recorded onto the probe span so the host half can
/// compare it with the identifier the Agent stamped on that same span.
///
/// Carried as an attribute rather than reported some other way because the comparison is
/// the point: an accessor returning *a* well-formed identifier that is not *the* one on the
/// telemetry would look correct on a support screen and find nothing in Kibana.
const String reportedSessionIdAttribute = 'test.reported.session.id';

/// Stands in for an identifier the platform could not give. An attribute that is simply
/// missing cannot be told apart from one the Plugin failed to record.
const String noSessionId = 'none';

/// Which platform ran, because what a readable Session identifier means differs by platform
/// (ADR-0001) and the host half has no other way to know.
const String platformAttribute = 'test.platform';

/// Wire name of the Agent's own Session identifier, per ADR-0003.
const String sessionIdAttribute = 'session.id';
