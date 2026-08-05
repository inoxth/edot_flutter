/// The user's permission state governing whether the Plugin emits telemetry at all.
///
/// Three-valued rather than a boolean so an unresolved consent flow is representable.
/// [pending] is not a third behaviour — it withholds telemetry exactly as [notGranted]
/// does — but it lets an app tell "the user declined" apart from "we have not asked
/// yet", and that is the distinction that decides whether to show the prompt again.
/// Collapsing the two would make a first launch indistinguishable from a refusal.
///
/// The wire values match this organisation's React Native SDK's `TrackingConsent`
/// union, which is why [notGranted] is `not_granted` rather than following Dart's
/// camelCase. Renaming one fleet without the other would split the vocabulary that
/// makes a single dashboard possible.
enum EdotTrackingConsent {
  /// The user has permitted telemetry. The only state that emits.
  granted('granted'),

  /// The user has declined telemetry.
  notGranted('not_granted'),

  /// The user has not answered yet. Withholds telemetry, like [notGranted].
  pending('pending');

  const EdotTrackingConsent(this.wireValue);

  /// The value this state is known by on the wire and in the React Native SDK.
  final String wireValue;

  /// Whether telemetry may be emitted in this state.
  ///
  /// Only [granted]. Written as one accessor rather than compared at each call site
  /// so that "which states emit" is decided in a single place — the kind of rule
  /// that goes wrong when it is spelled out three times.
  bool get allowsEmission => this == EdotTrackingConsent.granted;
}
