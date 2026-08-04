/// The surface an integration package is built on. Not for application code.
///
/// Separate from `inoxth_edot_flutter.dart` on purpose. An app instruments its
/// requests with [EdotHttpClient] or the Dio interceptor and never needs anything
/// here; a *transport* integration needs [EdotRequestTrace], and it has to be public
/// for the Dio package to reach it at all, because that package ships separately
/// (ADR-0010) and Dart has no visibility between packages.
///
/// `@internal` cannot say this: it would make every use from the Dio package an
/// analysis failure, which is the one use it exists for. A second library says it
/// instead — importing this is a deliberate act, and it keeps the surface an app
/// developer reads as small as it was.
///
/// See ADR-0013 for what an integration built on this must honour.
library;

export 'src/edot_request_trace.dart' show EdotRequestTrace;
