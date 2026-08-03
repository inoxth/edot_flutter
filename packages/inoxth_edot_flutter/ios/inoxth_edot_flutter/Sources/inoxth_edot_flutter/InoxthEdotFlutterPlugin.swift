import ElasticApm
import Flutter
import OpenTelemetryApi
import OpenTelemetrySdk
import UIKit

/// iOS side of the Plugin.
///
/// Under ADR-0002 the Agent is authoritative: it creates the real spans and owns
/// export, while Dart holds only Shadow Span identifiers. That plumbing lands in
/// the tracer-bullet ticket; today this registers the single channel and proves
/// the pinned Agent resolves and links.
public class InoxthEdotFlutterPlugin: NSObject, FlutterPlugin {
  /// Must match `edotChannelName` on the Dart side.
  private static let channelName = "inoxth_edot_flutter"

  /// Compile-time references to the pinned dependencies (ADR-0001).
  ///
  /// Without these, nothing in this target would touch the Agent or the
  /// OpenTelemetry SDK, so a wrong or unresolvable pin would go unnoticed until
  /// the first ticket that actually used them. Referencing a real symbol from
  /// each makes the build fail immediately instead.
  private static let pinnedAgentName = ElasticApmAgent.name
  private typealias PinnedTracerProvider = OpenTelemetryApi.TracerProvider
  private typealias PinnedTracerProviderSdk = OpenTelemetrySdk.TracerProviderSdk

  public static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(
      name: channelName,
      binaryMessenger: registrar.messenger()
    )
    registrar.addMethodCallDelegate(InoxthEdotFlutterPlugin(), channel: channel)
  }

  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    // No methods yet. Returning notImplemented is deliberate: the Dart side has
    // no callers, and a silent success here would hide a missing implementation
    // once it does.
    result(FlutterMethodNotImplemented)
  }
}
