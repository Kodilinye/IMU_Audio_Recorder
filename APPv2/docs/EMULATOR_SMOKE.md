# Emulator smoke checks — 2026-09-28

These are software checks on a disposable Google APIs **Android phone** emulator, API 36 (Android 16), ARM64 image revision 7, Emulator 37.1.11. They do not validate a physical phone, Wear OS, Galaxy Watch5, Pixel Watch 2, or OnePlus Watch 2. The camera is an emulated test pattern and emulator audio is synthetic/silent.

This is a record of the local run on 2026-09-28. Tools, emulator state, screenshots, captured samples, logs, and tested APKs were retained locally under the ignored `APPv2/.tools/` directory; evidence references below are relative to `.tools/emulator-smoke/`. These generated artifacts are intentionally not shipped in Git, so they are absent from a fresh checkout. No existing research data was read into or modified by these tests.

## Phone checks completed

| Check | Observed result |
| --- | --- |
| Install/launch | Debug APK installed and native UI opened on API 36. |
| Permissions | Camera, microphone, and notification dialogs appeared. Granting them returned to Ready without automatically starting. |
| Countdown cancellation | Tapped Start, then Cancel during countdown; waited over 7 seconds. Returned to Ready/Cancelled; session contains metadata and a closed marker, no MP4. |
| Record and local Stop | CameraX Start event produced Recording status, elapsed timer, and visible synthetic front-camera preview. Stop finalized a 51.05-second MP4, error code 0, no metadata failures. |
| Actual encoded format | MediaExtractor reported AVC 1280×720, 1,466 video samples, observed mean 28.716 fps, and emulator audio `audio/3gpp`, 8,000 Hz mono. These describe this emulator recording only. |
| Background/return | Home then return kept the same capture running. |
| Screen sleep/wake | A 3-second screen sleep followed by wake/unlock kept capture running; local Stop completed normally. |
| Video-only fallback | Revoked phone microphone permission between sessions. UI explicitly displayed video-only recording; a 23.82-second MP4 finalized with exactly one video track and no audio track. Microphone permission was restored afterward. |
| Activity recreation | Changed display density 420→440→420 during the video-only recording. Event logs confirmed two `onDestroy`/`onCreate` pairs; timer, preview, and recording continued. The app locks portrait, so this configuration change exercised recreation without relying on rotation. |
| File list and retrieval | Saved recordings listed the sessions. Export session ZIP opened Android's document picker and saved to Downloads. ZIP CRC checks passed; metadata and MP4 matched the private originals byte-for-byte and by SHA-256. |
| Visual inspection | Inspected screenshots of permission prompts, countdown, canceled state, recording, return from sleep, recreated activity, saved list, and export picker. Main controls and labels were readable at 1080×2400. |
| Crashes | Android crash log was empty after these checks. |

The exact phone binary tested was pulled from the emulator as `tested-phone.apk`; its SHA-256 is recorded in `environment.json`. `phone-sessions/` contains copied native session files; `sessions.tar` preserves the initial phone session snapshot; `exported-session.zip` and `export-verification.json` preserve the retrieval check. Screenshots and `activity-events.log` record the UI/lifecycle observations.

## Wear APK acquisition checks on the same phone emulator

After preserving all synthetic phone samples, the phone app was removed and the Wear APK installed on the same disposable **Android phone image**. This exercises native recording code but is not a Wear OS test and does not emulate the target watch hardware.

| Check | Observed result |
| --- | --- |
| Local countdown cancellation | Start then Cancel; waited over 7 seconds. Only closed metadata remained, with no WAV or CSV. |
| Offline recording and Stop | With no connected phone, motion and microphone acquisition started and ran for about 56.7 seconds, including a 3-second screen sleep/wake. Local Stop completed and marked the session closed with no capture failures. |
| WAV validity | Python `wave` read mono PCM16 at 44,100 Hz, 2,500,608 frames (56.703 seconds). File size 5,001,260 bytes exactly matched the RIFF length, data length, and frame count. Metadata frame count matched the file. |
| Audio fallback metadata | Emulator did not advertise UNPROCESSED support. Metadata explicitly reported VOICE_RECOGNITION fallback, matching client/device sample rate and channel count, and no app filtering/resampling. No physical microphone quality claim is implied. |
| Native motion CSV | Parsed 39,692 events across accelerometer, linear acceleration, gyroscope, magnetic field, gravity, rotation vector, and game rotation vector. Each sensor's row count matched metadata; per-sensor event timestamps were monotonic. Emulator-reported 100 Hz is synthetic behavior, not evidence about a watch's actual rate. |
| Forced process death | Force-stopped the collector during another capture, then relaunched. UI returned to Ready without automatically restarting. Metadata marked `interrupted_process_death`, with an empty recovery-failure list and closed marker. |
| Partial-file recovery | Recovered WAV had 130,240 mono PCM16 frames at 44,100 Hz (2.953 seconds); RIFF/data sizes matched the file. Partial CSV retained 2,086 rows with monotonic per-sensor timestamps. The session remains explicitly incomplete. |

Evidence is in `wear-sessions/`, `wear-sessions.tar`, `wear-sample-verification.json`, and `tested-wear.apk`; its exact binary hash is in `environment.json`. The samples remain separate from all research data.

An attempted 384×384 / density-320 phone display simulation caused **Pixel Launcher**, the emulator's system launcher, to crash because it cannot support that display configuration. The display was reset to its original 1080×2400 / density 420 before acquisition tests. `small-display-launcher-crash.log` identifies `com.google.android.apps.nexuslauncher`; these small-display screenshots are not watch-layout validation. Real round-screen layout testing is still required.

The phone emulator's Google Play services did not provide the Wearable API, so automatic transfer correctly stayed pending. This does not validate paired delivery. Its initially verbose user-facing exception prompted a concise connection/transfer status fix, separately checked in the final UI pass.

## Final UI pass

Installed both final APKs in turn after the last build and visually inspected their recorder and Device status screens at the restored phone display size. The Wear recorder shows its main control before the tenths-of-a-second timer and a concise transfer-pending message. Device status opens on both variants; the phone screen displays camera/microphone permission state and local storage path. Diagnostic transfer details are confined to Device status. No collector process appears in the final crash log; the earlier two Pixel Launcher crashes remain documented above.

The capture checks used the exact preserved `tested-phone.apk` and `tested-wear.apk`; the final UI pass used separately preserved `final-ui-phone.apk` and `final-ui-wear.apk`. All four SHA-256 hashes are in `environment.json`. Final screenshots are `final-phone-ui.png`, `final-phone-status.png`, `final-wear-ui.png`, and `final-wear-status.png`. This distinction avoids implying a full capture rerun after the final UI/protocol-only changes. The emulator was shut down after evidence collection.

## Emulator reproduction

The following example uses the Apple Silicon macOS bootstrap described in [BUILD.md](BUILD.md). Install optional packages with SDK Manager: `emulator` and `system-images;android-36;google_apis;arm64-v8a`. On other hosts, use your installed JDK/SDK paths and a system image compatible with that host; the recorded results above apply only to the stated ARM64 environment. Run from `APPv2` and keep the emulator environment local:

```sh
export JAVA_HOME="$PWD/.tools/jdk-17.0.20.1+1/Contents/Home"
export ANDROID_HOME="$PWD/.tools/android-sdk"
export ANDROID_USER_HOME="$PWD/.tools/android-user"
export ANDROID_AVD_HOME="$PWD/.tools/avd"
export ANDROID_EMULATOR_HOME="$PWD/.tools/emulator-user"
mkdir -p "$ANDROID_AVD_HOME" "$ANDROID_EMULATOR_HOME"
"$ANDROID_HOME/cmdline-tools/latest/bin/avdmanager" create avd \
  --name collector_phone_api36 --package 'system-images;android-36;google_apis;arm64-v8a' \
  --path "$ANDROID_AVD_HOME/collector_phone_api36.avd" --device pixel_7
"$ANDROID_HOME/emulator/emulator" -avd collector_phone_api36 \
  -no-window -no-audio -no-snapshot -no-boot-anim \
  -camera-front emulated -camera-back emulated -gpu swiftshader -memory 2048 -cores 2
```

Use `adb -s emulator-5554` to install, launch, capture screenshots, and operate this disposable emulator. The checks above used the normal app controls and system document picker. Retrieve generated test sessions with `adb exec-out run-as org.toothbrush.collector tar -cf - files/recordings`. Stop the emulator with `adb -s emulator-5554 emu kill` when finished.

Emulator checks do not demonstrate sensor accuracy, stable research sampling rates, unprocessed microphone behavior, paired Wear Data Layer delivery, OEM battery/screen-off behavior, or synchronization precision. Those require the physical-device checks in the project validation plan.
