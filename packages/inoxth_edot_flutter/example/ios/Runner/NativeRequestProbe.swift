import Flutter
import Foundation

/// Test scaffolding: performs an HTTP request from **native** code.
///
/// Seam 2 needs this to assert what the Agent's `URLSession` instrumentation does
/// and does not trace (ADR-0006). It cannot be done from Dart: `dart:io` uses its
/// own sockets and is invisible to the `URLSession` swizzle, so a Dart request
/// would exercise nothing.
///
/// Lives in the example app rather than the Plugin — it is a test fixture, not
/// something the Plugin should ship.
enum NativeRequestProbe {
  static let channelName = "inoxth_edot_flutter_example/native_request"

  static func register(with registry: FlutterPluginRegistry) {
    guard let registrar = registry.registrar(forPlugin: "NativeRequestProbe") else {
      return
    }

    let channel = FlutterMethodChannel(
      name: channelName,
      binaryMessenger: registrar.messenger()
    )

    channel.setMethodCallHandler { call, result in
      guard call.method == "get",
            let arguments = call.arguments as? [String: Any],
            let urlString = arguments["url"] as? String,
            let url = URL(string: urlString)
      else {
        result(FlutterMethodNotImplemented)
        return
      }

      // The response is deliberately ignored. Whether the request succeeded says
      // nothing about the exclusion; only whether a span was produced does, and
      // the instrumentation produces one either way.
      URLSession.shared.dataTask(with: url) { _, _, _ in
        DispatchQueue.main.async { result(nil) }
      }.resume()
    }
  }
}
