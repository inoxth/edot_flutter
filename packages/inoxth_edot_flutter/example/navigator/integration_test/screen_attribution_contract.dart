/// Shared contract between the two halves of the screen attribution test.
///
/// Deliberately free of Flutter imports: the host half runs under plain
/// `dart run`, where `dart:ui` does not exist.
library;

/// Two entries, so the host half can prove the identifier changes between them.
const String firstScreenName = 'Cart';
const String secondScreenName = 'Checkout';

const String spanOnFirstScreen = 'screen-attribution-first';
const String spanOnSecondScreen = 'screen-attribution-second';

/// Emitted after the Active View is cleared — must carry neither attribute.
const String spanWithNoScreen = 'screen-attribution-none';

/// Emitted on the first screen, so its identifier can be matched against the span
/// from the same entry. That match is what proves both signals read one source.
const String logOnFirstScreen = 'screen-attribution-log';

/// The wire names, per ADR-0003.
const String screenNameAttribute = 'screen.name';
const String screenIdAttribute = 'screen.id';

/// Stamped on the first span so the host half learns which platform ran.
///
/// It has to condition on that: `flush()` drains log records on Android only
/// (ADR-0011), so on iOS the log half of this contract cannot be asserted.
const String platformAttribute = 'test.platform';
