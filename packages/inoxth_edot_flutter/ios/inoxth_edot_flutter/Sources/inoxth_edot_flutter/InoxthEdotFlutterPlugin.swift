import ElasticApm
import Flutter
import OpenTelemetryApi
import OpenTelemetrySdk
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
    case "flush": flush(result)
    default: result(FlutterMethodNotImplemented)
    }
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
          let serverUrl = URL(string: serverUrlString)
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

    ElasticApmAgent.start(with: builder.build())
    started = true
    log("agent started for service '\(serviceName)'")
    result(nil)
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

    let span = OpenTelemetry.instance.tracerProvider
      .get(instrumentationName: Self.instrumentationScope, instrumentationVersion: nil)
      .spanBuilder(spanName: name)
      .setStartTime(time: Self.date(microsecondsSinceEpoch: startUs))
      .startSpan()

    spansLock.lock()
    spans[shadowId] = span
    spansLock.unlock()

    result(nil)
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

    // Traces and metrics only. The pinned OpenTelemetry Swift LoggerProviderSdk
    // exposes no forceFlush and does not surface its processor, and the Agent
    // builds that provider internally — so log records cannot be flushed here
    // and still wait for their batch timer (ADR-0001). Dart documents this.
    (OpenTelemetry.instance.tracerProvider as? TracerProviderSdk)?.forceFlush()
    if let meterProvider = OpenTelemetry.instance.meterProvider as? StableMeterProviderSdk {
      _ = meterProvider.forceFlush()
    }

    result(nil)
  }

  private func log(_ message: String) {
    if debug {
      os_log("[edot] %{public}@", message)
    }
  }
}
