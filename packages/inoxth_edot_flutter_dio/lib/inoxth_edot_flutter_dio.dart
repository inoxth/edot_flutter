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
/// The interceptor itself lands in the Dio ticket, once the network attribute set
/// and trace context propagation exist in core to reuse.
library;
