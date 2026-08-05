import ElasticApm
import Flutter
import OpenTelemetryApi
import OpenTelemetrySdk
import URLSessionInstrumentation
import UIKit
import os

/// iOS side of the Plugin.
///
/// Under ADR-0002 the Agent is authoritative: it holds the real spans and owns
/// export. Dart sends a Shadow Span identifier and this class keeps the mapping,
/// so span start and end need no reply.
public class InoxthEdotFlutterPlugin: NSObject, FlutterPlugin {
  private static let channelName = "inoxth_edot_flutter"
  private static let instrumentationScope = "inoxth_edot_flutter"

  private var started = false
  private var debug = false

  /// Shadow Span identifier to the real span, guarded because Dart dispatches
  /// from one thread while the Agent's own instrumentation runs on others.
  private var spans: [String: Span] = [:]
  private let spansLock = NSLock()

  /// Runs the blocking part of `flush` off the main thread.
  private let flushQueue = DispatchQueue(label: "co.inoxth.edot.flush")

  /// Replaces the Agent's own network instrumentation (ADR-0006). Held because
  /// `URLSessionInstrumentation` installs swizzles on init and must outlive it.
  private var networkInstrumentation: URLSessionInstrumentation?

  public static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(
      name: channelName,
      binaryMessenger: registrar.messenger()
    )
    registrar.addMethodCallDelegate(InoxthEdotFlutterPlugin(), channel: channel)
  }

  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "initialize": initialize(call, result)
    case "spanStart": spanStart(call, result)
    case "spanEnd": spanEnd(call, result)

    // Four methods rather than one, because this is where the integer/double
    // distinction would otherwise be lost: Flutter delivers both as NSNumber, and
    // `as? Int` succeeds on a double just as `as? Double` succeeds on an integer.
    // The method name is what carries the type, not the value's runtime class.
    case "spanSetString":
      setAttribute(call, result, as: String.self) { $0.setAttribute(key: $1, value: $2) }
    case "spanSetInt":
      setAttribute(call, result, as: Int.self) { $0.setAttribute(key: $1, value: $2) }
    case "spanSetDouble":
      setAttribute(call, result, as: Double.self) { $0.setAttribute(key: $1, value: $2) }
    case "spanSetBool":
      setAttribute(call, result, as: Bool.self) { $0.setAttribute(key: $1, value: $2) }

    case "spanRecordException":
      withSpan(call, result) { span, args in
        guard let type = args["type"] as? String,
              let message = args["message"] as? String
        else {
          self.log("spanRecordException with malformed arguments; dropped")
          return
        }
        Self.addExceptionEvent(
          to: span,
          type: type,
          message: message,
          stacktrace: args["stacktrace"] as? String)
      }
    case "spanMarkFailed":
      withSpan(call, result) { span, args in
        // OpenTelemetry Swift's Status carries a non-optional description, so an
        // absent one becomes empty rather than being omitted.
        span.status = .error(description: args["description"] as? String ?? "")
      }

    case "spanTraceContext": spanTraceContext(call, result)

    case "emitLog": emitLog(call, result)
    case "recordMetric": recordMetric(call, result)

    case "flush": flush(result)
    case "sessionId": sessionId(result)
    default: result(FlutterMethodNotImplemented)
    }
  }

  /// Replies with the Session identifier the Agent is stamping onto telemetry.
  ///
  /// `session(false)` rather than `session()`: the default argument refreshes the
  /// Session's inactivity timer, so reading the identifier would extend the Session
  /// — and a support screen displaying it would keep the Session alive for as long
  /// as someone looked at it.
  ///
  /// Nil before start, because the Agent has not begun a Session to report.
  private func sessionId(_ result: @escaping FlutterResult) {
    guard started else {
      result(nil)
      return
    }

    result(SessionManager.instance.session(false))
  }

  private func emitLog(_ call: FlutterMethodCall, _ result: @escaping FlutterResult) {
    guard started else {
      log("emitLog before initialize; dropped")
      result(nil)
      return
    }

    guard let args = call.arguments as? [String: Any],
          let severityName = args["severity"] as? String,
          let message = args["message"] as? String,
          let timestampUs = args["timestampUs"] as? Int
    else {
      log("emitLog with malformed arguments; dropped")
      result(nil)
      return
    }

    OpenTelemetry.instance.loggerProvider
      .get(instrumentationScopeName: Self.instrumentationScope)
      .logRecordBuilder()
      .setSeverity(severity(from: severityName))
      // Dart's timestamp, applied verbatim (ADR-0005). Without it a record held
      // before start would be dated when the Agent replayed it rather than when it
      // happened, which for an early-startup error is the one thing worth knowing.
      .setTimestamp(Self.date(microsecondsSinceEpoch: timestampUs))
      .setBody(.string(message))
      .setAttributes(decodeTaggedAttributes(args["attributes"]))
      .emit()

    result(nil)
  }

  private func recordMetric(_ call: FlutterMethodCall, _ result: @escaping FlutterResult) {
    guard started else {
      log("recordMetric before initialize; dropped")
      result(nil)
      return
    }

    guard let args = call.arguments as? [String: Any],
          let name = args["name"] as? String,
          let value = args["value"] as? Double,
          let kind = args["metricType"] as? String
    else {
      log("recordMetric with malformed arguments; dropped")
      result(nil)
      return
    }

    // String-valued only, and here that is the platform talking rather than a
    // simplification: this Agent is on the deprecated meter provider, whose only
    // label API takes [String: String] (ADR-0012). Dart's type already enforces it.
    let dimensions = decodeStringAttributes(args["attributes"])

    let meter = OpenTelemetry.instance.meterProvider
      .get(instrumentationName: Self.instrumentationScope, instrumentationVersion: nil)

    switch kind {
    case "counter":
      meter.createDoubleCounter(name: name).add(value: value, labels: dimensions)
    case "histogram":
      meter
        .createDoubleHistogram(name: name, explicitBoundaries: nil, absolute: true)
        .record(value: value, labels: dimensions)
    case "upDownCounter":
      // The legacy meter has no up-down instrument; a non-monotonic counter is
      // the same thing under a different name.
      meter
        .createDoubleCounter(name: name, monotonic: false)
        .add(value: value, labels: dimensions)
    default:
      log("recordMetric: unknown metric kind '\(kind)'; dropped")
    }

    result(nil)
  }

  /// Maps the wire severity onto OpenTelemetry's.
  ///
  /// The wire values are the React Native SDK's lowercase names rather than
  /// OpenTelemetry's own spellings, so the mapping is explicit — a lookup by name
  /// would drift silently if either side renamed a level.
  private func severity(from wire: String) -> Severity {
    switch wire {
    case "trace": return .trace
    case "debug": return .debug
    case "info": return .info
    case "warn": return .warn
    case "error": return .error
    case "fatal": return .fatal
    default:
      log("unknown severity '\(wire)'; recording as INFO")
      return .info
    }
  }

  /// Decodes the type-tagged attribute list Dart sends for log records.
  ///
  /// The tag is what makes an integer attribute recoverable here: Flutter delivers
  /// every number as an `NSNumber`, which casts to `Int` and `Double` alike, so the
  /// value alone cannot say which it is.
  private func decodeTaggedAttributes(_ raw: Any?) -> [String: AttributeValue] {
    guard let entries = raw as? [[String: Any]] else { return [:] }

    var attributes: [String: AttributeValue] = [:]
    for entry in entries {
      guard let key = entry["key"] as? String, let type = entry["type"] as? String
      else { continue }

      // Dropping is the only option once the tag and the value disagree, but it is
      // never silent: a caller who believes an attribute was recorded needs to be
      // told it was not.
      guard let value = Self.attributeValue(type: type, raw: entry["value"]) else {
        log("attribute '\(key)' does not decode as '\(type)'; dropped")
        continue
      }

      attributes[key] = value
    }

    return attributes
  }

  private static func attributeValue(type: String, raw: Any?) -> AttributeValue? {
    switch type {
    case "string": return (raw as? String).map(AttributeValue.string)
    case "int": return (raw as? Int).map(AttributeValue.int)
    case "double": return (raw as? Double).map(AttributeValue.double)
    case "bool": return (raw as? Bool).map(AttributeValue.bool)
    default: return nil
    }
  }

  /// Applies one typed attribute to the Shadow Span a call refers to.
  ///
  /// Generic over the value type so the cast, and the log when it fails, live in
  /// one place rather than being repeated per type. `T` is fixed at each call
  /// site, which is what selects the right `setAttribute` overload — and which is
  /// how the integer/double distinction survives a channel that has already
  /// collapsed both into `NSNumber`.
  private func setAttribute<T>(
    _ call: FlutterMethodCall,
    _ result: @escaping FlutterResult,
    as type: T.Type,
    _ apply: @escaping (Span, String, T) -> Void
  ) {
    withSpan(call, result) { span, args in
      guard let key = args["key"] as? String, let value = args["value"] as? T
      else {
        self.log("\(call.method) with a malformed key or value; dropped")
        return
      }
      apply(span, key, value)
    }
  }

  /// Resolves the Shadow Span a call refers to and hands it to [action].
  ///
  /// Never replies with an error: none of these calls is awaited in Dart
  /// (ADR-0002), so an error would surface as an unhandled channel failure
  /// detached from the call site rather than at it.
  private func withSpan(
    _ call: FlutterMethodCall,
    _ result: @escaping FlutterResult,
    _ action: (Span, [String: Any]) -> Void
  ) {
    guard let args = call.arguments as? [String: Any],
          let shadowId = args["shadowId"] as? String
    else {
      log("\(call.method) with malformed arguments; dropped")
      result(nil)
      return
    }

    spansLock.lock()
    let span = spans[shadowId]
    spansLock.unlock()

    guard let span else {
      // Ordinarily an ended span, which Dart already guards against. Reaching
      // here means the two sides disagree about the span's lifetime.
      log("\(call.method) for unknown shadow id '\(shadowId)'; dropped")
      result(nil)
      return
    }

    action(span, args)
    result(nil)
  }

  // MARK: - Lifecycle

  private func initialize(_ call: FlutterMethodCall, _ result: @escaping FlutterResult) {
    if started {
      // Dart guards this too, but the guard belongs on both sides: two agents
      // would mean two export pipelines racing.
      result(FlutterError(code: "already_initialized",
                          message: "The Agent is already running.",
                          details: nil))
      return
    }

    guard let args = call.arguments as? [String: Any],
          let serviceName = args["serviceName"] as? String,
          let serviceVersion = args["serviceVersion"] as? String,
          let environment = args["deploymentEnvironment"] as? String,
          let serverUrlString = args["serverUrl"] as? String,
          let serverUrl = URL(string: serverUrlString),
          let collectorHost = args["collectorHost"] as? String
    else {
      result(FlutterError(code: "invalid_config",
                          message: "Missing or malformed configuration arguments.",
                          details: nil))
      return
    }

    debug = args["debug"] as? Bool ?? false

    if args["disableAgent"] as? Bool == true {
      log("agent disabled by configuration; not starting")
      result(nil)
      return
    }

    // apm-agent-ios 1.2.1's AgentConfigBuilder has no service-identity setters,
    // so identity must arrive through the resource environment variable, which
    // AgentEnvResource reads at start. Both deployment.environment spellings are
    // set: the Agent hardcodes one, and APM Server 8.16+ reads
    // deployment.environment.name, so telemetry would otherwise land
    // unattributed against a newer stack.
    //
    // This encoding is comma and equals delimited, which is exactly why Dart
    // rejects those characters in identity values before we get here.
    setResourceAttributes([
      "service.name": serviceName,
      "service.version": serviceVersion,
      "deployment.environment": environment,
      "deployment.environment.name": environment,
    ])

    var builder = AgentConfigBuilder()
      .withServerUrl(serverUrl)
      .useConnectionType(args["exportProtocol"] as? String == "grpc" ? .grpc : .http)

    if let rate = args["sessionSamplingRate"] as? Double {
      builder = builder.withSessionSampleRate(rate)
    }
    if let apiKey = args["apiKey"] as? String {
      builder = builder.withApiKey(apiKey)
    } else if let secretToken = args["secretToken"] as? String {
      builder = builder.withSecretToken(secretToken)
    }

    // The Agent's built-in URLSession instrumentation is on/off only, and it
    // traces the Agent's own export because that goes through URLSession.shared.
    // Turning it off here and installing a filtered equivalent below is what
    // ADR-0006 calls for — disabling it outright would leave native-origin
    // traffic untraced, which is a different blind spot rather than a fix.
    //
    // Everything else follows the iOS configuration block, whose defaults are the
    // Agent's own. Read with `?? true` rather than `?? false`: a value missing from
    // the map means an older Dart side that does not know the option, and answering
    // "off" would silently turn instrumentation off during an upgrade.
    let ios = args["ios"] as? [String: Any] ?? [:]
    let instrumentation = InstrumentationConfigBuilder()
      .withURLSessionInstrumentation(false)
      .withCrashReporting(ios["crashReportingEnabled"] as? Bool ?? true)
      .withSystemMetrics(ios["systemMetricsEnabled"] as? Bool ?? true)
      .withAppMetricInstrumentation(ios["appMetricsEnabled"] as? Bool ?? true)
      .withLifecycleEvents(ios["lifecycleEventsEnabled"] as? Bool ?? true)
      .build()

    ElasticApmAgent.start(with: builder.build(), instrumentation)

    // Must follow start, not precede it: URLSessionInstrumentation resolves its
    // tracer once at init, and before start that resolves to a provider the Agent
    // has not registered yet, so every span would go nowhere.
    //
    // The cost is a gap — anything requested during start is traced by neither the
    // Agent's instrumentation nor ours. In practice that is the Agent's own first
    // central-config poll, which is scheduled immediately and which we would
    // exclude anyway. Application traffic in that window would be missed.
    installFilteredNetworkInstrumentation(collectorHost: collectorHost)

    started = true
    log("agent started for service '\(serviceName)', excluding host '\(collectorHost)'")
    result(nil)
  }

  /// Traces native `URLSession` traffic, except to the Collector Host.
  ///
  /// Mirrors what the Agent's own instrumentation produces — same span naming and
  /// same error events — so telemetry is unchanged apart from the exclusion. It
  /// deliberately omits the Agent's `createdRequest` network-status injection:
  /// `ElasticSpanProcessor.onStart` already injects those attributes into every
  /// span, so doing it here too would be redundant.
  private func installFilteredNetworkInstrumentation(collectorHost: String) {
    let configuration = URLSessionInstrumentationConfiguration(
      shouldInstrument: { request in
        // ADR-0006: host equality and nothing else. No path condition, because
        // enumerating the Agent's endpoints leaked twice in the React Native SDK
        // when the list turned out to be incomplete. No port condition, because
        // the Agent normalises default ports away and comparing them caused the
        // original miss.
        //
        // Lowercased because hosts are case-insensitive and Dart has already
        // lowercased its side, so a mixed-case server URL must not slip through.
        request.url?.host?.lowercased() != collectorHost.lowercased()
      },
      nameSpan: { request in
        guard let host = request.url?.host, let method = request.httpMethod else {
          return nil
        }
        return "\(method) \(host)"
      },
      receivedResponse: { response, _, span in
        guard let httpResponse = response as? HTTPURLResponse,
              (400...599).contains(httpResponse.statusCode)
        else { return }

        Self.addExceptionEvent(
          to: span,
          type: "\(httpResponse.statusCode)",
          message: HTTPURLResponse.localizedString(
            forStatusCode: httpResponse.statusCode),
          escaped: false)
      },
      receivedError: { error, _, _, span in
        Self.addExceptionEvent(
          to: span,
          type: String(describing: type(of: error)),
          message: error.localizedDescription,
          escaped: false)
      })

    networkInstrumentation = URLSessionInstrumentation(configuration: configuration)
  }

  /// Records an exception event on a span.
  ///
  /// [escaped] and [stacktrace] are omitted when nil rather than sent empty, so
  /// each caller emits only what it actually knows. The network instrumentation
  /// passes `escaped: false` to match what the Agent's own instrumentation emits;
  /// ADR-0003's error vocabulary does not include that attribute, so a recorded
  /// exception leaves it out and sends a stack trace instead.
  private static func addExceptionEvent(
    to span: Span,
    type: String,
    message: String,
    stacktrace: String? = nil,
    escaped: Bool? = nil
  ) {
    var attributes: [String: AttributeValue] = [
      SemanticAttributes.exceptionType.rawValue: .string(type),
      SemanticAttributes.exceptionMessage.rawValue: .string(message),
    ]
    if let stacktrace {
      attributes[SemanticAttributes.exceptionStacktrace.rawValue] =
        .string(stacktrace)
    }
    if let escaped {
      attributes[SemanticAttributes.exceptionEscaped.rawValue] = .bool(escaped)
    }

    span.addEvent(
      name: SemanticAttributes.exception.rawValue,
      attributes: attributes)
  }

  private func setResourceAttributes(_ attributes: [String: String]) {
    let encoded = attributes.map { "\($0.key)=\($0.value)" }.joined(separator: ",")
    setenv("OTEL_RESOURCE_ATTRIBUTES", encoded, 1)
  }

  // MARK: - Spans

  private func spanStart(_ call: FlutterMethodCall, _ result: @escaping FlutterResult) {
    guard started else {
      // Not an error result: Dart does not await this call, so an error would
      // surface as an unhandled channel failure rather than at the call site.
      log("spanStart before initialize; dropped")
      result(nil)
      return
    }

    guard let args = call.arguments as? [String: Any],
          let shadowId = args["shadowId"] as? String,
          let name = args["name"] as? String,
          let startUs = args["startUs"] as? Int
    else {
      log("spanStart with malformed arguments; dropped")
      result(nil)
      return
    }

    let builder = OpenTelemetry.instance.tracerProvider
      .get(instrumentationName: Self.instrumentationScope, instrumentationVersion: nil)
      .spanBuilder(spanName: name)
      .setStartTime(time: Self.date(microsecondsSinceEpoch: startUs))

    // Parenting is always stated, never inherited. OpenTelemetry would otherwise
    // fall back to the active span on whichever thread this arrives on, and a
    // Dart span silently adopting some unrelated native span as its parent is
    // precisely the plausible-but-wrong tree this design avoids. ADR-0002: native
    // context is thread-local and has no link back to the Dart caller.
    if let parentShadowId = args["parentShadowId"] as? String {
      spansLock.lock()
      let parent = spans[parentShadowId]
      spansLock.unlock()

      if let parent {
        builder.setParent(parent)
      } else {
        // Ended before its child started, which is a caller bug. Logged rather
        // than hidden; the span becomes a root.
        log("parent shadow id '\(parentShadowId)' is not active; starting a root")
        builder.setNoParent()
      }
    } else {
      builder.setNoParent()
    }

    builder.setSpanKind(spanKind: spanKind(from: args["kind"] as? String))

    // Applied before startSpan so samplers and processors see them. Dart owns
    // which attributes these are and what they are called — the Elastic Mobile
    // Attribute Set lives there (ADR-0003, ADR-0004), not in two native files.
    for (key, value) in decodeStringAttributes(args["attributes"]) {
      builder.setAttribute(key: key, value: value)
    }

    spansLock.lock()
    spans[shadowId] = builder.startSpan()
    spansLock.unlock()

    result(nil)
  }

  /// Maps the wire span kind onto OpenTelemetry's.
  ///
  /// Absent means internal, which is what every span was before an outbound
  /// transport needed to say otherwise.
  private func spanKind(from wire: String?) -> SpanKind {
    switch wire {
    case nil, "internal": return .internal
    case "client": return .client
    default:
      log("unknown span kind '\(wire ?? "")'; recording as INTERNAL")
      return .internal
    }
  }

  /// Decodes a plain string-valued attribute map.
  ///
  /// Key by key rather than casting the map whole, because one bad value would fail
  /// a whole-map cast and take every other attribute down with it.
  private func decodeStringAttributes(_ raw: Any?) -> [String: String] {
    var decoded: [String: String] = [:]

    for (key, value) in (raw as? [String: Any]) ?? [:] {
      guard let text = value as? String else {
        log("dropping non-string attribute '\(key)'")
        continue
      }
      decoded[key] = text
    }

    return decoded
  }

  private func spanEnd(_ call: FlutterMethodCall, _ result: @escaping FlutterResult) {
    guard let args = call.arguments as? [String: Any],
          let shadowId = args["shadowId"] as? String,
          let endUs = args["endUs"] as? Int
    else {
      log("spanEnd with malformed arguments; dropped")
      result(nil)
      return
    }

    spansLock.lock()
    let span = spans.removeValue(forKey: shadowId)
    spansLock.unlock()

    guard let span else {
      log("spanEnd for unknown shadow id '\(shadowId)'; dropped")
      result(nil)
      return
    }

    span.end(time: Self.date(microsecondsSinceEpoch: endUs))
    result(nil)
  }

  /// Replies with the W3C Trace Context headers for a Shadow Span.
  ///
  /// The one call Dart waits for (ADR-0002): the real trace and span ids are here,
  /// not in Dart.
  ///
  /// Built by the propagator rather than formatted by hand, so the header is
  /// whatever this OpenTelemetry version says W3C means — and so `tracestate` comes
  /// along when the span carries one. It writes only its own fields, which is also
  /// what keeps the deprecated `elastic-apm-traceparent` out.
  ///
  /// An empty map for an unknown span, which Dart treats as "no context": the
  /// request goes out uncorrelated rather than not at all.
  private func spanTraceContext(_ call: FlutterMethodCall, _ result: @escaping FlutterResult) {
    guard let args = call.arguments as? [String: Any],
          let shadowId = args["shadowId"] as? String
    else {
      log("spanTraceContext with malformed arguments; no context returned")
      result([String: String]())
      return
    }

    spansLock.lock()
    let span = spans[shadowId]
    spansLock.unlock()

    guard let span else {
      log("spanTraceContext for unknown shadow id '\(shadowId)'; no context returned")
      result([String: String]())
      return
    }

    var headers: [String: String] = [:]
    W3CTraceContextPropagator().inject(
      spanContext: span.context,
      carrier: &headers,
      setter: DictionarySetter())

    result(headers)
  }

  /// Carries injected headers into a dictionary. OpenTelemetryApi declares the
  /// protocol but ships no implementation of it.
  private struct DictionarySetter: Setter {
    func set(carrier: inout [String: String], key: String, value: String) {
      carrier[key] = value
    }
  }

  private static func date(microsecondsSinceEpoch: Int) -> Date {
    Date(timeIntervalSince1970: Double(microsecondsSinceEpoch) / 1_000_000)
  }

  // MARK: - Flush

  private func flush(_ result: @escaping FlutterResult) {
    guard started else {
      result(FlutterError(code: "not_initialized",
                          message: "The Agent is not running.",
                          details: nil))
      return
    }

    // forceFlush blocks its caller — BatchSpanProcessor waits on its operation
    // queue, and the export writes to the Agent's on-disk buffer (ADR-0011). This
    // handler runs on the main thread, so waiting here would stall the UI on a
    // disk write. Dart awaits the reply either way.
    flushQueue.async {
      // Traces only, and that is everything this Agent can do (ADR-0011).
      //
      // Log records: LoggerProviderSdk exposes no forceFlush and does not surface
      // its processor, and the Agent builds it internally.
      //
      // Metrics: the Agent registers the *deprecated* MeterProviderBuilder, so
      // this is a MeterProviderSdk, which has no forceFlush either — it pushes on
      // a 60-second interval held in a non-public property. An earlier version of
      // this code cast to StableMeterProviderSdk, which the value never is, so it
      // silently did nothing. Do not reinstate that cast without first checking
      // the Agent has moved to the stable provider.
      (OpenTelemetry.instance.tracerProvider as? TracerProviderSdk)?.forceFlush()

      // Flutter requires the reply on the main thread.
      DispatchQueue.main.async { result(nil) }
    }
  }

  private func log(_ message: String) {
    if debug {
      os_log("[edot] %{public}@", message)
    }
  }
}
