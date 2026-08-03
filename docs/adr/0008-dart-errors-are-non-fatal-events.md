# Dart Errors are non-fatal events, kept separate from Native Crashes

Status: accepted

## Context

The Agents' crash reporting emits events that Kibana's mobile dashboard reads as crashes, feeding
crash-free rate — the one metric mobile teams actually alert on.

Dart Errors are almost never fatal. A `FlutterError` during build paints a red screen and the app
runs on; an uncaught async error may be entirely recoverable. Emitting them in the crash event shape
would give a single unified crash-free rate, which is what people intuitively ask for, but a noisy
layout overflow would then tank it and the metric would stop being trustworthy.

Since Flutter 3.3, `PlatformDispatcher.instance.onError` catches uncaught async errors, so capturing
them does not require the app to wrap `main()` in `runZonedGuarded`. That removes the usual reason to
make error capture opt-in.

## Decision

Agent initialisation installs handlers for `FlutterError.onError`, `PlatformDispatcher.instance.onError`
and isolate errors, **chaining to any handler already registered** so that an incumbent reporter keeps
working. Each Dart Error becomes a log record carrying `exception.type`, `exception.message`,
`exception.stacktrace` and `error.source`, marked non-fatal. When a span is active it additionally
records the exception and takes error status.

Native Crashes remain a separate signal and the only input to crash-free rate.

## Consequences

- Crash-free rate reflects Native Crashes only. Dart Errors are queried as error events. This distinction must be explicit in the docs, because it is the opposite of what most users assume.
- The Plugin takes over global error handlers at initialisation. Chaining makes coexistence with Crashlytics or Sentry safe for Dart-level errors; signal-level contention is a separate matter, see ADR-0009.
- Dart stack traces are not symbolicated. Release builds using `--obfuscate --split-debug-info` produce unreadable frames and Elastic performs no Dart de-obfuscation. The React Native SDK ships a source-map upload CLI for the equivalent problem; a Dart symbol-upload tool is deferred.
