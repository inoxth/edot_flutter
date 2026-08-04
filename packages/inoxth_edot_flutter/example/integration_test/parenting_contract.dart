/// Shared contract between the two halves of the span parenting test.
///
/// Deliberately free of Flutter imports: the host half runs under plain
/// `dart run`, where `dart:ui` does not exist.
library;

/// A parent and a child created inside its scope.
const String parentSpanName = 'parenting-parent';
const String childSpanName = 'parenting-child';

/// A child created after one or more `await` boundaries inside the same scope.
const String awaitedChildSpanName = 'parenting-child-after-await';

/// Created with no ambient and no explicit parent — must export as a root in its
/// own trace.
const String rootSpanName = 'parenting-root';

/// Two flows whose children are created in the opposite order to their parents,
/// so a "most recently started span wins" implementation would cross them.
const String flowOneParentName = 'parenting-flow-one';
const String flowTwoParentName = 'parenting-flow-two';
const String flowOneChildName = 'parenting-flow-one-child';
const String flowTwoChildName = 'parenting-flow-two-child';

/// Child given an explicit parent while a different one is ambient.
const String explicitParentName = 'parenting-explicit-parent';
const String explicitChildName = 'parenting-explicit-child';
