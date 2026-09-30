# Toothbrush Collector · APPv2

Native Kotlin Wear OS collector and Android phone companion, independently implemented from the authoritative top-level Apple application that collected the Toothbrush dataset. APPv2 lives in its own directory; the original Apple source remains unchanged at the repository root. Research data is not included.

## Install the two apps

Download the [APPv2 preview APKs](https://github.com/Kodilinye/IMU_Audio_Recorder/releases/tag/appv2-v1.0-preview): install `appv2-wear-debug.apk` on the Wear OS watch and `appv2-phone-debug.apk` on its paired Android phone. These development builds share one signing certificate. The download includes `SHA256SUMS.txt` for verification; no signing key or recordings are distributed.

Follow [installation instructions](docs/BUILD.md#install-the-preview-apks) for ADB commands. This is a software-tested preview for lab evaluation; physical-watch and paired-transfer validation remain outstanding. Complete the [device checks](docs/VALIDATION.md#remaining-physical-validation) before using it to collect study data.

## Build and run from source

Clone the APPv2 branch and enter its independent Android project:

```sh
git clone --branch appv2-wearos-android https://github.com/Kodilinye/IMU_Audio_Recorder.git
cd IMU_Audio_Recorder/APPv2
```

Follow [BUILD.md](docs/BUILD.md) to install JDK 17 and Android SDK 36, or use the optional Apple Silicon macOS bootstrap. Toolchains and signing keys are created locally and are not included in the checkout. Then run these commands from `APPv2` using Bash (Git Bash on Windows); the adapter tests require Python 3.10+:

```sh
./scripts/build.sh
python3 -m unittest discover -s tools -p 'test_apple_compat.py' -v
```

Install `wear/build/outputs/apk/debug/wear-debug.apk` on the watch and `phone/build/outputs/apk/debug/phone-debug.apk` on its paired Android phone. Both APKs must use the same signing certificate. Full prerequisites, fresh-machine setup and ADB commands are in [BUILD.md](docs/BUILD.md).

1. Open both apps, grant permissions, and wait for companion status. Set an optional suffix on the phone; it is shared with the watch.
2. Tap **Start recording** on either device. Both receive the same session identity and five-second target. **Cancel** remains available during countdown/opening.
3. **Stop & save** works locally even without the companion. A persistent notification also offers Stop. A disconnected companion cannot receive an immediate Stop; a scoped Stop is retried when communication returns. Use its local Stop if necessary.
4. Watch files queue automatically after finalization; **Send data to phone / Retry watch transfer** retries them. Originals remain on the watch even after verified receipt.
5. On the phone, **Saved recordings → Export session ZIP** saves the available session files through the document picker.

A paired start requires both apps visible because camera/microphone foreground services need while-in-use authorization. A started watch recording uses a foreground service and renewed partial wake lock for screen-off acquisition. Watch-only recording works offline and reports unconfirmed/absent phone video. Phone microphone denial permits clearly identified video-only capture. File presence does not prove a complete recording; check its metadata.

## Data

Each recording lives in a UUID directory. Files share the Apple-style local-time stem `yyyyMMdd_HHmmss[_suffix]`, while UUID directories prevent collisions:

| File | Contents |
| --- | --- |
| `motion_native_<stem>.csv` | One native sensor event per row; sensor type, monotonic acquisition and arrival timestamps, accuracy, unchanged values |
| `audio_<stem>.wav` | Watch PCM16 mono, actual sample rate in header; 44.1 kHz preferred, native-rate fallback documented |
| `video_<stem>.mp4` | Phone front-camera recording, with audio when permitted; native encoded track formats and timing inspected at finalization |
| `watch_metadata_<stem>.json`, `phone_metadata_<stem>.json` | Identity, device, clock anchor, actual formats/rates, timing observations, missing streams, errors, completion status |

The watch requests 100 Hz separately for each available Android motion sensor. Actual rates are measured; missing signals are not manufactured. Android fusion, axes, gravity sign and orientation references are not automatically Core Motion equivalents. There is no collection-time filtering or resampling. The optional [compatibility exporter](docs/DATA_COMPATIBILITY.md) requires explicit acknowledgement, converts units, joins by stated tolerance, preserves native files, and leaves unvalidated Apple attitude columns blank. It is **not a validated drop-in input** to the existing orientation-dependent analysis.

The five-second countdown coordinates intent; it does not measure clock offset or align camera frames, audio samples and sensor events precisely.

## Structure and verification

- `core`: small JVM state, naming, WAV and verified-receipt functions with tests.
- `shared`: native Android controls, foreground recording ownership and Wear Data Layer transport, compiled into both apps.
- `wear`: one sensor/audio implementation for Galaxy Watch5, Pixel Watch 2 and OnePlus Watch 2; runtime capability checks instead of unverified device-specific assumptions.
- `phone`: CameraX front-camera capture, audio and finalized track inspection.
- `tools`: offline compatibility export and synthetic tests.

See [source-grounded parity](docs/FEATURE_PARITY.md), [transfer behavior](docs/TRANSFER.md), and [validation and remaining device checks](docs/VALIDATION.md). No accounts, cloud service, guidance sequences, labels, scoring or classification are added.
