## 0.0.1

First release. Dio integration for `inoxth_edot_flutter`.

* `EdotDioInterceptor` traces every request a `Dio` instance makes as one client span,
  carrying the Elastic Mobile Attribute Set and the Active View's screen attributes
  (ADR-0003).
* Drives the same `EdotRequestTrace` as the plugin's own `EdotHttpClient`, so the URL
  sanitizer, both exclusion rules and the trace-propagation decision are applied in one
  place for both and the two integrations cannot drift (ADR-0013).
* Records a request already traced by another transport only once, leaving a marked
  request alone (ADR-0014).
* Ships as its own package because Dart has no optional dependencies, so bundling it
  would impose Dio's version constraint on every consumer (ADR-0010).
* Platform floors and pins inherited from `inoxth_edot_flutter` 0.0.1: iOS 15.6,
  Android API 24, Flutter 3.44, Dio ^5.4.0.
