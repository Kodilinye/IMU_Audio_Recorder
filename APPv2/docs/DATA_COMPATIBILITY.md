# Native data and the optional Apple-column export

APPv2 preserves native Android sensor events and raw watch audio. Similar column
names do not establish equivalence with Core Motion. The optional exporter is
explicitly a **unit-only, unvalidated native-axis export**. It is suitable for
inspecting numbers using familiar column names; it is not a validated drop-in
input for existing orientation-dependent research models.

## Evidence from the existing collector and data

The authoritative acquisition source inspected was the repository-root Apple file, preserved alongside the `APPv2` directory:

`IMU_Audio_Recorder Watch App Watch App/DataRecorder.swift`

It requests 100 Hz Core Motion device updates, writes `userAcceleration` (gravity
removed), rotation rate, magnetic field, attitude, and gravity, and obtains each
CSV timestamp from `Date().timeIntervalSince1970`. It requests 44,100 Hz mono
PCM16 audio. Apple motion/audio names are `motion_yyyyMMdd_HHmmss[_suffix].csv`
and `audio_yyyyMMdd_HHmmss[_suffix].wav`. Neither matching filenames nor a shared
countdown prove sample synchronization. APPv2 recording identity and its metadata
remain authoritative when filenames collide or differ across devices.

The exact original CSV header is:

```text
timestamp,accel_x(G),accel_y(G),accel_z(G),gyro_x(rad/s),gyro_y(rad/s),gyro_z(rad/s),mag_x(uT),mag_y(uT),mag_z(uT),attitude_roll(rad),attitude_pitch(rad),attitude_yaw(rad),gravity_x(G),gravity_y(G),gravity_z(G)
```

The following sources were inspected read-only in the separate Toothbrush research project. Paths below are relative to that project's root; the project and research recordings are not included in this repository. Line numbers describe the versions reviewed on 2026-09-28:

- `my1/preprocessing/imu_audio_processor.py`: exact column
  names (lines 44–56); timestamp handling (114–124); interpolation (302–325);
  quaternion/Euler transforms (355–410).
- `my1/preprocessing/config.py`: 100 Hz IMU target and
  offline filter defaults (lines 66–69).
- `my1/preprocessing/imu_naming.py`: timestamp-first
  filename matching and historical suffix patterns.
- `audio_motion_participant_held_out/prepare_data.py`:
  int16 mono audio validation and whole-recording offline resampling (326–331).
- `originaldata/expirment 2/audio`: all 89 WAV headers
  inspected on 2026-09-28 were valid uncompressed 44,100 Hz mono PCM16; RIFF and
  data lengths matched file sizes. Only headers were needed for this check.
- Two labeled motion CSVs from the uncontrolled and controlled experiment
  collections: small row samples confirmed original column names, Unix-second
  timestamps and approximately 10 ms sampling with gaps; one sample also
  contained backward time. Participant filenames are omitted from this
  documentation.

Research files add `time_seconds,label` or
`time_seconds,region,segment_label` after acquisition. APPv2 does not invent
annotations or reproduce those downstream research workflows. An observed pair
followed the pattern `audio_<timestamp>.wav` and
`labeled_motion_<timestamp>_<suffix>.csv`; identical basenames are not required
by existing matching code.

## Native contract

The sensor CSV contains one event per row:

```text
sensor_type,event_timestamp_ns,arrival_elapsed_ns,accuracy,v0,v1,v2,v3,v4,v5
```

`event_timestamp_ns` is the Android sensor event's monotonic timestamp.
`arrival_elapsed_ns` records callback arrival on the same device monotonic time
base. Neither is a Unix timestamp. Sensor types have independent sampling times;
the file must not pretend asynchronous samples were captured simultaneously.
Blank trailing components mean no supplied value, not measured zero. Accuracy
retains the Android event value. Native event rows and metadata remain available
after any export.

| Android type | Native quantity | Compatibility handling |
| --- | --- | --- |
| 1 accelerometer | Acceleration including gravity, m/s² | Preserved in source; never substituted for type 10 |
| 10 linear acceleration | Platform gravity-removed estimate, m/s² | Divide by exactly 9.80665; use its event times as export rows |
| 4 gyroscope | rad/s | Retain values; nearest-time join |
| 2 magnetic field | μT | Retain values; nearest-time join |
| 9 gravity | Platform gravity estimate, m/s² | Divide by exactly 9.80665; native signs retained |
| 11 rotation vector | Android rotation-vector components | Preserved in source; no Apple Euler conversion |
| 15 game rotation vector | Android game rotation-vector components | Preserved in source; no Apple Euler conversion |

The recorder's metadata supplies one paired clock observation:

```json
{"clock_anchor": {"epoch_ms": 1700000000123, "elapsed_ns": 1000000000}}
```

The exporter maps each linear-acceleration event using integer arithmetic:

```text
Unix seconds = (epoch_ms × 1,000,000 + event_timestamp_ns − elapsed_ns) / 1,000,000,000
```

Nine decimal places preserve arithmetic precision; they do not claim nanosecond
wall-clock accuracy. Clock adjustment after this anchor does not reverse the
derived timeline. The anchor does not measure phone/watch clock offset, audio
capture latency, sensor fusion delay, or camera start delay.

## Run the adapter

Python 3.10+ standard library is sufficient. Run from APPv2:

```sh
python3 tools/apple_compat.py /path/to/native_motion.csv /path/to/watch_metadata.json \
  /path/to/new/motion_20260928_120000_example.csv \
  --allow-unvalidated-axes --tolerance-ms 20
python3 -m unittest discover -s tools -p 'test_apple_compat.py' -v
```

The output directory must already exist. The acknowledgement flag is mandatory.
The exporter writes exactly the original 16 headers and a sibling
`motion_20260928_120000_example.compat.json`. It refuses existing output files,
source aliases, malformed native CSV, missing clock anchors, non-finite
measurements, and non-increasing timestamps within any sensor stream. It also
rejects an arrival timestamp earlier than its event. It never sorts away, fixes,
or suppresses bad events silently. Type 10 must exist; missing other sensors are
reported and left blank.

There is no interpolation, target-frequency grid, filtering, audio processing,
or resampling. Each original type-10 event produces exactly one output row. Each
other exported sensor uses its nearest original event within the inclusive
tolerance, selecting the earlier event on a tie. A later source event or reuse
of the same source event on adjacent rows is possible and recorded in the
sidecar. Values outside tolerance and absent components are blank. Measured
zeros stay zeros. All three attitude columns remain blank, including when
rotation vectors are present.

The sidecar records source paths and SHA-256 hashes, clock mapping, joining rule,
selected sensor types, row counts, source sample reuse, time-difference ranges,
missing components, and observed sampling statistics per native stream. Its
30 ms gap threshold is an explicit descriptive metric, not an estimate of lost
samples. The source hashes and deterministic join rule permit reproduction of
individual sample choices. Native CSV retains every original timestamp.

## Scientific limits and subsequent analysis

Android device axes, wrist placement, watch rotation, gravity signs, attitude
reference frame, and vendor sensor fusion need physical verification against the
intended analysis convention. Unit conversion alone does not resolve them. In
particular, the adapter deliberately does **not** negate Android gravity and
claim it is Core Motion gravity. It applies no hidden body-frame rotation.

The existing IMU processor subtracts the first second's mean Euler angles and
constructs `Rz(yaw) Ry(pitch) Rx(roll)`; it prefers `quat_w/x/y/z` when present.
The unchanged pipeline will not safely handle the intentionally blank attitude
columns. Do not feed this export directly into that transform and interpret its
outputs as validated: select an analysis that explicitly handles unavailable
attitude, or establish and independently test a frame conversion first. No such
conversion is implemented here. Keeping native rotation-vector measurements
allows that future work without recollecting or falsifying the source.

Existing pipelines resample IMU offline to 100 Hz and may filter IMU at 0.5–20 Hz
and audio at 500–8,000 Hz. Another audio pipeline converts PCM16 with `/32768`
and resamples whole recordings to 16 kHz. These are analysis decisions, never
collection-time requirements. Preserve the original actual-rate audio; a
device fallback sample rate must be read from its WAV header and metadata before
choosing downstream processing. A 44.1 kHz request is not proof that every target
watch supports the same unprocessed microphone path.

Synthetic software checks cover export semantics and file safety. They establish
no claim of physical sensor equivalence, microphone frequency response, actual
watch sampling performance, or inter-device synchronization.
