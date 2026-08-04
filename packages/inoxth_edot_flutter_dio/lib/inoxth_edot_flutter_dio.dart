/// Dio integration for `inoxth_edot_flutter`.
///
/// Separate from the core package on purpose (ADR-0010): Dart has no optional
/// dependencies, so shipping the interceptor in core would impose Dio's version
/// constraint on every consumer — meaning a Dio major release would block apps
/// that never use Dio until a new core release shipped.
///
/// Do not merge this into the core package for convenience. That reintroduces
/// exactly the coupling this split exists to avoid.
///
/// ```dart
/// dio.interceptors.add(EdotDioInterceptor());
/// ```
///
/// What a request records, and which requests are traced at all, comes from the core
/// package's `EdotRequestTrace` — the same object `EdotHttpClient` drives.
/// This package holds only what is Dio's own: reading a `RequestOptions`, and knowing
/// that Dio raises a 4xx as an exception where `package:http` returns it.
library;

export 'src/edot_dio_interceptor.dart' show EdotDioInterceptor;
