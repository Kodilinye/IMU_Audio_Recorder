# Build and install

Work from `APPv2`. The three Gradle modules are `core` (plain JVM Kotlin), `wear`, and `phone`. Both Android applications use application ID `org.toothbrush.collector` and the same signing key, which the Wear Data Layer requires. Install each APK on its intended device.

## Install the preview APKs

To try the apps without compiling, download `appv2-wear-debug.apk`, `appv2-phone-debug.apk`, and `SHA256SUMS.txt` from the [APPv2 preview release](https://github.com/Kodilinye/IMU_Audio_Recorder/releases/tag/appv2-v1.0-preview). Keep the files together. On macOS, verify them with `shasum -a 256 -c SHA256SUMS.txt`; on Linux, use `sha256sum -c SHA256SUMS.txt`.

Install Android SDK Platform Tools, enable USB or wireless debugging, and run these commands from the download directory:

```sh
adb devices -l
adb -s WATCH_SERIAL install -r appv2-wear-debug.apk
adb -s PHONE_SERIAL install -r appv2-phone-debug.apk
```

Replace the serial placeholders with the corresponding entries from `adb devices -l`. Both apps must be installed on their intended devices. Pairing, permissions, wireless debugging and file export are described [below](#install-and-retrieve-files).

These are debug builds for lab evaluation. Both APKs use the same certificate, but your own build generates a different local key. Android will reject an update signed by a different key: export recordings before uninstalling to switch builds. No private signing key is included. Hardware behavior and paired transfer still require the [physical validation checks](VALIDATION.md#remaining-physical-validation).

## Clone and prerequisites

Clone the branch containing APPv2, then enter its Android project:

```sh
git clone --branch appv2-wearos-android https://github.com/Kodilinye/IMU_Audio_Recorder.git
cd IMU_Audio_Recorder/APPv2
```

A fresh checkout does not contain a JDK, Android SDK, signing key, or generated APKs. All commands below run from `APPv2`. The original Apple project remains at the repository root and is independent of this build.

For Apple Silicon macOS, run the optional bootstrap:

```sh
./scripts/setup-macos-arm64.sh
```

It downloads pinned JDK 17 and Android command-line archives from Adoptium and Google, verifies their SHA-256 checksums, and installs SDK 36, Build Tools 35, and Platform Tools. On first installation the SDK manager displays its license prompts. Downloads and tools stay inside the ignored `.tools/` directory; the bootstrap does not change global Java/SDK settings.

For Linux, Intel macOS, Windows, or an existing toolchain, install JDK 17 and Android SDK packages `platforms;android-36`, `build-tools;35.0.0`, and `platform-tools`, accept the applicable SDK licenses, and set `JAVA_HOME` and `ANDROID_HOME` to those installations. Android Studio's SDK Manager can install the SDK packages. The shell scripts require Bash: use a Bash terminal on macOS/Linux or **Git Bash on Windows**, with both environment variables available in that terminal. PowerShell and Command Prompt do not interpret `build.sh`. The optional bootstrap above is only for Apple Silicon macOS.

Python 3.10+ is needed only for the compatibility exporter and its tests; they use the standard library. Commands use `python3`; substitute `python` if that is the name of your Python 3.10+ interpreter.

## Build

Build, run core tests, and create both debug APKs:

```sh
./scripts/build.sh
python3 -m unittest discover -s tools -p 'test_apple_compat.py' -v
```

Individual checks:

```sh
./scripts/build.sh :core:test
./scripts/build.sh :wear:assembleDebug :phone:assembleDebug
./scripts/build.sh :wear:lintDebug :phone:lintDebug
```

Outputs are `wear/build/outputs/apk/debug/wear-debug.apk` and `phone/build/outputs/apk/debug/phone-debug.apk`. JUnit HTML results appear in `core/build/reports/tests/test/index.html`. For Android Studio, open the `APPv2` directory with JDK 17 configured for Gradle. Run `build.sh` once before building from the IDE or invoking the Gradle wrapper directly so the shared local development keystore exists.

`build.sh` uses existing `JAVA_HOME` / `ANDROID_HOME` when supplied; otherwise it finds the local `.tools/jdk-17*` and `.tools/android-sdk`. It sets `GRADLE_USER_HOME` and `ANDROID_USER_HOME` within `.tools/`, creates `.tools/debug.keystore` if missing, and delegates to the checked-in Gradle wrapper. The wrapper pins the Gradle distribution checksum. The development key is excluded from source control. Retain it for updates to already installed debug apps; changing the key requires uninstalling those apps, which removes their private files. Export recordings before an uninstall. A distributed release needs both APKs signed with the same private release key.

## Pinned dependencies

| Component | Version |
| --- | --- |
| JDK / optional local bootstrap | 17 / Temurin 17.0.20.1+1 |
| Gradle | 8.13 |
| Android Gradle Plugin | 8.13.2 |
| Kotlin | 2.2.21 |
| Compile / target SDK | 36 / 36 |
| Minimum SDK | Wear 30; phone 29 |
| Android SDK Build Tools | 35.0.0 (AGP default) |
| AndroidX Core / Lifecycle Service | 1.17.0 / 2.9.4 |
| Google Wearable Data Layer | 19.0.0 |
| CameraX | 1.5.1 |
| JUnit | 4.13.2 |

This is a stable API 36 build configuration, not a claim to use every newest library. [AGP 8.13 compatibility](https://developer.android.com/build/releases/agp-8-13-0-release-notes) documents Gradle 8.13, JDK 17, and support up through API 36.1. Native Views are used; Compose is not a dependency.

## Install and retrieve files

Enable developer options and USB or wireless debugging on the phone/watch. Pair the Wear OS watch with its Android phone using the device manufacturer's normal companion application. Ensure Google Play services is available on both. Add your SDK's `platform-tools` directory to `PATH` for these commands, or replace `adb` with its full path. With the local macOS bootstrap, that path is `./.tools/android-sdk/platform-tools/adb`.

```sh
adb devices -l
adb -s PHONE_SERIAL install -r phone/build/outputs/apk/debug/phone-debug.apk
adb -s WATCH_SERIAL install -r wear/build/outputs/apk/debug/wear-debug.apk
```

For wireless debugging, use the device's displayed pairing address and pairing code with `adb pair HOST:PAIR_PORT`, then its debugging address with `adb connect HOST:DEBUG_PORT`. Addresses and ports may differ.

Open both apps and grant the requested permissions. Phone camera permission is required for video; declining its microphone allows video-only recording. Keep the phone app visible for a paired start so Android can authorize its camera/microphone foreground service. Watch recording can proceed offline. A disconnected or unavailable phone is reported; a countdown alone does not prove synchronized capture.

On the phone, **Saved recordings → Export session ZIP** writes the selected session through Android's document picker. Watch originals remain available for automatic or manual retry. Do not treat file presence as proof of complete capture: inspect each session's metadata and failures.

## Validation boundary

No physical Android phone, Galaxy Watch5, Pixel Watch 2, or OnePlus Watch 2 was connected at the initial ADB check. Local compilation and JVM tests do not validate sensor availability, actual sample rates, camera codecs, microphone audio-source behavior, wrist-down recording, battery behavior, or paired transfer on those watches. See [emulator smoke checks](EMULATOR_SMOKE.md) for software checks actually completed and the project validation record for remaining physical-device checks. Emulator samples are synthetic test data, not research data.
