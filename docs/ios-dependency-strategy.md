# iOS Dependency Strategy: SwiftPM / CocoaPods Hybrid

> Analysis of the iOS dependency setup introduced by PR #41 (`feat(capture)`), and a recommendation for how to resolve it. **Read-only analysis — no build config was changed by this doc.**

## Recommendation (TL;DR)

**Keep the hybrid, but document and stabilise it — do NOT chase "fully SPM" or revert to "fully CocoaPods" right now.**

The hybrid is not a hand-rolled mess; it is **Flutter's own per-plugin resolver** doing exactly what it is designed to do. Flutter's Swift Package Manager support (enabled on the build machine) routes each plugin to SPM *if the plugin ships a `Package.swift`*, and falls back to CocoaPods otherwise. So:

- **Firebase + camera → SPM** (those plugins ship SPM manifests).
- **ML Kit + TFLite + ARKit → CocoaPods** (those plugins have not adopted SPM yet — confirmed by Flutter's own build output).

This split is **automatic and will self-heal**: as `google_mlkit_*`, `tflite_flutter`, and `arkit_plugin` adopt SPM upstream, they migrate over with zero local work. Fighting it now (forcing all-Pods or all-SPM) means working *against* the Flutter tool, which it will undo on the next `flutter pub get`.

**The real, urgent problem is not the hybrid — it is that the TestFlight CI pipeline has never gone green and dies before it ever builds the hybrid.** See [Blocking issue](#blocking-issue-ci-has-never-proven-the-hybrid) below. That is the thing to fix first.

Three concrete actions, in priority order:

1. **Fix the CI signing failure** (the actual blocker — every TestFlight run fails at *Import signing certificate*, never reaching the build). This is a secrets problem, not a dependency problem.
2. **Pin Flutter's SPM mode explicitly in CI** so the resolver behaviour is reproducible and not dependent on a global machine flag.
3. **Suppress / accept the cosmetic base-config warning** — it is harmless and pre-dates the hybrid. Documented below so nobody chases it again.

---

## Current state: the SPM vs CocoaPods split

Evidence cross-checked from three independent sources, all agreeing:
`Podfile.lock`, `Runner.xcworkspace/xcshareddata/swiftpm/Package.resolved`, and the live CI build log (run `26923722458`, which prints "The following plugins do not support Swift Package Manager for ios").

| Dependency (Flutter plugin) | Resolver | Evidence |
|---|---|---|
| `firebase_core` / `firebase_auth` / `cloud_firestore` / `firebase_storage` | **SwiftPM** | `Package.resolved` pins `firebase-ios-sdk 11.15.0` + `flutterfire 3.15.2`; **absent** from `Podfile.lock` |
| `camera` (`camera_avfoundation`) | **SwiftPM** | In `pubspec.yaml:24`; **absent** from `Podfile.lock` |
| `google_mlkit_text_recognition` / `google_mlkit_commons` | **CocoaPods** | `Podfile.lock:7-13`; named in CI "do not support SPM" list |
| `tflite_flutter` (TensorFlowLite 2.12.0) | **CocoaPods** | `Podfile.lock:81-85`; named in CI list |
| `arkit_plugin` (GLTFSceneKit) | **CocoaPods** | `Podfile.lock:2-4,88`; named in CI list |
| Flutter engine + generated plugin registrant | **SwiftPM (local)** | `project.pbxproj:786` `XCLocalSwiftPackageReference "FlutterGeneratedPluginSwiftPackage"` |

### How the split is actually wired

- `Runner.xcodeproj/project.pbxproj` contains **exactly one** SPM package reference: a *local* package, `Flutter/ephemeral/Packages/FlutterGeneratedPluginSwiftPackage` (`project.pbxproj:786-794`). There are **no** `XCRemoteSwiftPackageReference` entries hand-added for Firebase. Firebase arrives transitively: the `FlutterGeneratedPluginSwiftPackage` (regenerated on every build) depends on the `firebase_core` etc. plugin packages, which in turn depend on `firebase-ios-sdk`. That is why `Package.resolved` is populated with Firebase even though the pbxproj never names it.
- The CocoaPods side is a normal Flutter Podfile (`Podfile:30-37`, `flutter_install_all_ios_pods`). It installs only the **non-SPM** plugins. `Podfile.lock` is correspondingly small — 5 direct dependencies, none of them Firebase or camera.
- **What changed in PR #41:** `Package.resolved` first appears in commit `8f8f3438` (#41), and the pre-#41 `Podfile.lock` (parent `d399c479`, the build-8 state) contained **all** of Firebase, camera, ML Kit, TFLite on CocoaPods. So #41 is exactly where Firebase + camera flipped to SPM. This was a side effect of having Flutter's SPM mode enabled on the build machine at the time `flutter pub get` regenerated the iOS scaffolding — not a deliberate hand-migration.

> **Portability caveat:** Flutter's SPM mode is a **global, per-machine** setting (`flutter config --enable-swift-package-manager`), *not* tracked in the repo. A machine where it is **off** would resolve Firebase + camera back onto CocoaPods, producing a *different* dependency graph from the same source tree. CI currently has it on (the "do not support SPM" warning only prints when SPM is enabled), but nothing in the repo guarantees that. This is the single most fragile thing about the current setup and is addressed in action 2 of the recommendation.

---

## The "couldn't set base config" warning — root cause

The warning text is CocoaPods':

> `[!] CocoaPods did not set the base configuration of your project because your project already has a custom config set. ... use the base configuration ... or include the `Pods-Runner.*.xcconfig` in your build configuration.`

**Root cause — it is a pre-existing standard-Flutter artifact, not a #41 regression:**

The Runner target's **Profile** build configuration uses `Release.xcconfig` as its base configuration reference (`project.pbxproj:521-525`, config object `249021D4...`). The standard Flutter xcconfigs are:

- `Flutter/Debug.xcconfig` → `#include? "Pods/.../Pods-Runner.debug.xcconfig"` then `#include "Generated.xcconfig"`
- `Flutter/Release.xcconfig` → `#include? "Pods/.../Pods-Runner.release.xcconfig"` then `#include "Generated.xcconfig"`

There is **no `Profile.xcconfig`**. The Profile configuration reuses `Release.xcconfig`, which `#include?`s the **release** Pods xcconfig — not a `Pods-Runner.profile.xcconfig`. When `pod install` runs, CocoaPods generates a `Pods-Runner.profile.xcconfig` and wants to set the Profile config's base reference to it, but finds the slot already occupied by `Release.xcconfig` (a config CocoaPods did not author). It refuses to overwrite a user/Flutter-owned base config and emits the warning.

Confirming it is **not** caused by the hybrid:
- The parent commit `d399c479` (pre-#41, all-CocoaPods) has the identical `Release.xcconfig` base-config layout (4 references, same as now). The warning would have fired there too; it was just unremarkable when every dependency was on Pods.
- The `#include?` (note the `?`) means the include is **optional** — the build does not fail if the Pods xcconfig is missing. So the warning is **cosmetic**: settings still flow because the Debug/Release Pods xcconfigs are included, and Profile inherits Release's. The only practical risk is that Profile-configuration builds get *release* Pods settings rather than *profile* ones — which is exactly what the Podfile's `'Profile' => :release` mapping (`Podfile:9`) already intends.

**Verdict:** harmless. It is the well-known Flutter "Profile config reuses Release.xcconfig" quirk meeting CocoaPods' refusal-to-clobber policy. Suppress it or leave it; do not restructure xcconfigs to silence it (that risks breaking the include chain for no real gain).

---

## Blocking issue: CI has never proven the hybrid

This is the headline operational finding and the reason the prior "completed" claim was overstated.

- **Every** TestFlight workflow run has **failed** — 10/10 most-recent runs, going back past #41 (`gh run list --workflow=testflight.yml`).
- The latest run (`26923722458`, 2026-06-04) fails at the **`Import signing certificate`** step — a secrets/keychain problem. The build step (`flutter build ipa`) is **never reached**, so the hybrid iOS build has **never been compiled in CI**.
- `ci.yml` runs Dart analyze + Flutter test only; it has **no iOS build step** (`grep -niE 'pod|build ipa|xcode' .github/workflows/ci.yml` → nothing but a path filter). So no workflow anywhere compiles the iOS app.
- `testflight.yml` calls `flutter pub get` then `flutter build ipa` (`testflight.yml:44-99`). It **never runs `pod install` explicitly** and never resolves/caches SPM explicitly — it relies entirely on Flutter's build to drive both resolvers, with no verification that either succeeded.

So "a local IPA built" is the *only* evidence the hybrid works, and it depends on the local machine's global SPM flag. **The hybrid is unproven in any reproducible environment.**

---

## The three options, with trade-offs

### Option A — Stable documented hybrid (RECOMMENDED)

Keep Firebase + camera on SPM and ML Kit + TFLite + ARKit on CocoaPods, because that is what Flutter chooses per-plugin. Make it reproducible and stop fighting it.

| | |
|---|---|
| **Work required** | Low. Fix CI signing (separate from deps). Pin SPM mode in CI. Add a `pod install` + SPM-resolve verification step. Suppress the cosmetic warning. |
| **Pros** | Works *with* the Flutter tool, so it survives `flutter pub get`. Self-heals as laggard plugins adopt SPM. Smaller `Podfile.lock`, fewer transitive Pod conflicts (Firebase's heavy Pod graph moves to SPM where Apple's resolver handles it). Matches Flutter's stated direction (SPM is becoming default). |
| **Cons** | Two resolvers to reason about. The global-SPM-flag portability trap must be pinned explicitly or a fresh machine silently diverges. Cosmetic warning remains (suppressible). |
| **Risk** | Low — this is the path of least resistance and least surprise. |

### Option B — Fully CocoaPods (revert to build-8 state)

Disable Flutter SPM (`flutter config --no-enable-swift-package-manager`), `flutter clean`, `flutter pub get`, regenerate iOS scaffolding so Firebase + camera fall back to Pods. `Podfile.lock` returns to the pre-#41 shape (Firebase/camera/ML Kit/TFLite all on Pods, confirmed present in parent `d399c479`).

| | |
|---|---|
| **Work required** | Medium. Flip the flag, regenerate, re-verify the full Pod graph resolves (Firebase's Pod graph is large), re-test a local IPA, commit the regenerated `Podfile.lock` and a cleaned pbxproj (the `FlutterGeneratedPluginSwiftPackage` reference would be removed). |
| **Pros** | Single resolver — simplest mental model. Proven to work (it is the build-8 state that shipped to Seray's phone). No global-flag portability trap. |
| **Cons** | Swims *against* Flutter's direction — every future `flutter pub get` on an SPM-enabled machine re-introduces the hybrid, so the whole team must keep SPM disabled. Loses Apple-native resolution of Firebase. Eventually forced off it: Flutter has announced SPM will become the default and the "does not support SPM" warning "will become an error in a future version of Flutter." |
| **Risk** | Medium — low technical risk now, but it is a treadmill: you are perpetually undoing what the tool wants to do. |

### Option C — Fully SwiftPM

Wait for / pressure ML Kit, TFLite, ARKit to ship SPM manifests, then drop CocoaPods entirely.

| | |
|---|---|
| **Work required** | **Blocked — not currently possible.** `google_mlkit_text_recognition`, `google_mlkit_commons`, `tflite_flutter`, and `arkit_plugin` do **not** ship `Package.swift` (Flutter's own build output lists all four as unsupported). You cannot force-SPM a plugin that has no SPM manifest. |
| **Pros** | Eventual end state: single modern resolver, no Podfile, faster clean builds, aligned with Flutter's roadmap. |
| **Cons** | Gated entirely on three upstream maintainers. ML Kit (Google) and TFLite are notably slow to adopt SPM. Could be a year+ away, or require swapping those plugins for SPM-native alternatives (non-trivial — TFLite and ML Kit are load-bearing for the scanner). |
| **Risk** | N/A today — it is simply not achievable without upstream changes or plugin swaps. |

---

## Why A over B and C

- **C is impossible today** — three core plugins have no SPM support; the scanner cannot drop TFLite/ML Kit.
- **B is a regression treadmill** — it works, but it fights the tool. Every `flutter pub get` on a default-configured (SPM-on) machine re-creates the hybrid, so the whole team has to remember to keep SPM off, forever, until Flutter forces the issue anyway.
- **A accepts reality** — the hybrid is what Flutter produces, it self-heals as upstreams adopt SPM, and the only genuine fragility (the unpinned global SPM flag) is a one-line CI fix. The loud problems (CI never green, build never proven) are *orthogonal to the dependency split* and must be fixed regardless of which option you pick.

## Follow-up tasks implied by this analysis (not done here)

1. **Fix TestFlight CI signing** — the `Import signing certificate` step fails on every run; the IPA has never built in CI. (Blocker; unrelated to deps.)
2. **Pin Flutter SPM mode in `testflight.yml`** — add an explicit `flutter config --enable-swift-package-manager` step (or `--no-` for Option B) so the resolver split is reproducible and not dependent on the runner's global default.
3. **Add a build-only iOS CI gate** (e.g. `flutter build ios --no-codesign` in `ci.yml`) so the hybrid is compiled on PRs *before* it hits the signing-gated TestFlight job — this is what would have caught any real hybrid breakage.
4. **Suppress the base-config warning** if it bothers anyone — it is cosmetic and pre-dates the hybrid; do not restructure xcconfigs to chase it.

---

*Evidence files: `recycled_sound/ios/Podfile`, `recycled_sound/ios/Podfile.lock`, `recycled_sound/ios/Runner.xcodeproj/project.pbxproj`, `recycled_sound/ios/Runner.xcworkspace/xcshareddata/swiftpm/Package.resolved`, `recycled_sound/pubspec.yaml`, `.github/workflows/testflight.yml`, `.github/workflows/ci.yml`. CI evidence: TestFlight run `26923722458`.*
