# Validation record

Date: 2026-09-28. The implementation and all generated build/test artifacts are within APPv2. The Apple collector and Toothbrush research files were inspected read-only. No code or data from the excluded prior implementation was used.

## Successful local checks

- Debug APK assembly for both `wear` and `phone` with JDK 17, Gradle 8.13, AGP 8.13.2 and SDK 36.
- **22 JVM JUnit tests**: countdown monotonic scheduling; cancel before due; Stop before reordered Start; stale and duplicate commands; old callbacks after a new session; UUID collision protection; zero-frame WAV and first PCM preservation; recovery and idempotent close; valid byte transfer; short/oversize/corrupt transfer rejection; duplicate receipt; destination conflict protection; interrupted reads; sender status ordering, process generations and retirement.
- **12 Python tests**: exact Apple headers; unit conversion without resampling; explicit acknowledgement; blank unavailable/stale signals and attitude; nearest-time tolerance and tie behavior; fixed clock anchor; malformed/nonmonotonic input and overwrite rejection.
- Both APK signatures verify and share the same development certificate, as required by Data Layer. APK SHA-256 hashes are in `validation-results.json`.
- The compatibility adapter also processed the actual synthetic watch-capture output: 5,669 native linear-acceleration rows exported, with all attitude fields blank as designed. This checks the acquisition/export contract together.
- Android lint for both modules: no errors after resolving the AudioRecord permission check. Remaining warnings concern pinned dependency updates, localization/style suggestions, shared min-SDK guards, application-context ownership and portrait behavior. They are not hidden by a blanket baseline.

Commands:

```sh
./scripts/build.sh :core:test :wear:assembleDebug :phone:assembleDebug :wear:lintDebug :phone:lintDebug
python3 -m unittest discover -s tools -p 'test_apple_compat.py' -v
```

JUnit reports: `core/build/reports/tests/test/index.html` and `core/build/test-results/test/*.xml`. Lint reports: each app's `build/reports/lint-results-debug.html`. The emulator-specific observations are in `EMULATOR_SMOKE.md`; emulator sensor/camera data is synthetic and is not evidence of research measurement equivalence.

## Remaining physical validation

No physical Android phone or target Wear OS watch was attached. Complete the following on **each Galaxy Watch5, Pixel Watch 2 and OnePlus Watch 2**, recording its OS/build and pairing with the intended Android phone:

| Check | Required evidence |
| --- | --- |
| Permissions and camera | Fresh install; grant/deny/permanent denial; phone video-only microphone fallback; front camera and playable MP4 audio/video; no false recording state on failure |
| Paired workflow | Phone-initiated and watch-initiated five-second countdown; Cancel during countdown/setup; duplicate rapid taps; local/notification Stop; correct shared suffix/UUID |
| Timing | Compare scheduled target, sensor first timestamps, AudioTimestamp observations and phone frame timing; independently measure inter-device offset if needed by the research analysis |
| Wrist-down | Capture for a representative study duration with screen off; verify every sensor's measured rate/gaps, continuous PCM and elapsed time; test OS battery settings and thermal behavior |
| Native sensor meaning | Known static poses and signed rotations; gravity polarity, axes/wrist orientation, gyro units, magnetometer availability/accuracy; rotation-vector frame vs intended Apple analysis |
| Audio | WAV header and PCM count match; actual client/device rate/source/route; microphone spectral response; fallback/routing changes, silencing and other-app interruptions |
| Offline operation | Disconnect before/during recording; local Stop/save still succeeds; video absence explicit; reconnect never starts an expired session; pending Stop affects only its recording |
| Transfer integrity | Large session over Bluetooth/Wi-Fi; disconnect during transfer, reconnect/retry, repeat ACK; compare watch and phone SHA-256; originals retained; retry after app/process restart |
| Resource failure | Storage nearly full, permission revocation, service/process termination and reboot; partial data retained, WAV recovery marked, no claim of completed clean capture |
| Retrieval | Phone lists complete and incomplete sessions; ZIP export through document picker; no overwrites across same-second filenames in different UUID directories |

These checks remain outstanding. Successful builds, synthetic tests and emulation do not establish scientific equivalence or certify all three watches for a study.
