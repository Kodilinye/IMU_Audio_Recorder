#!/usr/bin/env python3
"""Opt-in Apple-column-shaped export; native Android axes are NOT Apple-equivalent."""

from __future__ import annotations

import argparse
from bisect import bisect_left
import csv
from dataclasses import dataclass
from decimal import Decimal, InvalidOperation
import hashlib
import json
from pathlib import Path
import statistics
import sys


RAW_HEADERS = [
    "sensor_type", "event_timestamp_ns", "arrival_elapsed_ns", "accuracy",
    "v0", "v1", "v2", "v3", "v4", "v5",
]
APPLE_HEADERS = [
    "timestamp", "accel_x(G)", "accel_y(G)", "accel_z(G)",
    "gyro_x(rad/s)", "gyro_y(rad/s)", "gyro_z(rad/s)",
    "mag_x(uT)", "mag_y(uT)", "mag_z(uT)",
    "attitude_roll(rad)", "attitude_pitch(rad)", "attitude_yaw(rad)",
    "gravity_x(G)", "gravity_y(G)", "gravity_z(G)",
]
STANDARD_GRAVITY = Decimal("9.80665")
SENSOR_NAMES = {
    1: "TYPE_ACCELEROMETER", 2: "TYPE_MAGNETIC_FIELD", 4: "TYPE_GYROSCOPE",
    9: "TYPE_GRAVITY", 10: "TYPE_LINEAR_ACCELERATION", 11: "TYPE_ROTATION_VECTOR",
    15: "TYPE_GAME_ROTATION_VECTOR",
}
EXPORT_TYPES = (10, 4, 2, 9)
LIMITATIONS = [
    "UNVALIDATED NATIVE ANDROID AXES: unit conversion only; not Apple measurement equivalence.",
    "No device-axis rotation, acceleration/gravity sign correction, reference-frame conversion, or calibration is applied.",
    "All Apple attitude columns are blank: Android rotation-vector/Euler conventions are not mapped to Core Motion.",
    "Android linear acceleration and gravity are platform estimates; their fusion and filtering may differ from Core Motion.",
    "Nearest-time joins can reuse or select a later sample; sensors did not necessarily sample simultaneously.",
    "A fixed wall/monotonic clock anchor is an estimate, not proof of watch/audio/phone synchronization.",
    "Blank or stale measurements require explicit handling before existing research preprocessing can be used.",
]


class ExportError(ValueError):
    pass


@dataclass(frozen=True)
class Sample:
    timestamp_ns: int
    values: tuple[Decimal | None, ...]


def _integer(value: object, name: str, minimum: int = 0) -> int:
    if isinstance(value, bool):
        raise ExportError(f"{name} must be an integer")
    if isinstance(value, int):
        result = value
    elif isinstance(value, str) and value and value.isascii() and value.isdecimal():
        result = int(value)
    else:
        raise ExportError(f"{name} must be an integer")
    if result < minimum:
        raise ExportError(f"{name} must be >= {minimum}")
    return result


def _decimal(value: str, name: str) -> Decimal | None:
    if not value:
        return None
    try:
        number = Decimal(value)
    except InvalidOperation as error:
        raise ExportError(f"{name} is not numeric") from error
    if not number.is_finite():
        raise ExportError(f"{name} must be finite or blank")
    return number


def read_native(path: Path) -> dict[int, list[Sample]]:
    streams: dict[int, list[Sample]] = {}
    with path.open(newline="", encoding="utf-8") as handle:
        reader = csv.DictReader(handle)
        if reader.fieldnames != RAW_HEADERS:
            raise ExportError("Native CSV headers must exactly match the documented acquisition contract")
        for line, row in enumerate(reader, 2):
            if None in row or any(value is None for value in row.values()):
                raise ExportError(f"CSV line {line} has an incorrect number of fields")
            sensor = _integer(row["sensor_type"], f"line {line} sensor_type", 1)
            timestamp = _integer(row["event_timestamp_ns"], f"line {line} event_timestamp_ns", 1)
            arrival = _integer(row["arrival_elapsed_ns"], f"line {line} arrival_elapsed_ns", 1)
            if arrival < timestamp:
                raise ExportError(f"CSV line {line}: arrival precedes its sensor event")
            try:
                accuracy = int(row["accuracy"])
            except ValueError as error:
                raise ExportError(f"CSV line {line}: invalid accuracy") from error
            if accuracy not in (-1, 0, 1, 2, 3):
                raise ExportError(f"CSV line {line}: invalid Android sensor accuracy")
            values = tuple(_decimal(row[f"v{i}"], f"line {line} v{i}") for i in range(6))
            stream = streams.setdefault(sensor, [])
            if stream and timestamp <= stream[-1].timestamp_ns:
                raise ExportError(f"CSV line {line}: non-increasing timestamps for sensor {sensor}")
            stream.append(Sample(timestamp, values))
    if not streams.get(10):
        raise ExportError("TYPE_LINEAR_ACCELERATION (10) is required; total acceleration is never substituted")
    return streams


def read_anchor(path: Path) -> tuple[int, int]:
    with path.open(encoding="utf-8") as handle:
        metadata = json.load(handle)
    anchor = metadata.get("clock_anchor") if isinstance(metadata, dict) else None
    if not isinstance(anchor, dict):
        raise ExportError("Metadata must contain clock_anchor:{epoch_ms,elapsed_ns}")
    return (
        _integer(anchor.get("epoch_ms"), "clock_anchor.epoch_ms", 1),
        _integer(anchor.get("elapsed_ns"), "clock_anchor.elapsed_ns"),
    )


def _sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for block in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def _sensor_statistics(stream: list[Sample]) -> dict:
    times = [sample.timestamp_ns for sample in stream]
    periods = [right - left for left, right in zip(times, times[1:])]
    return {
        "samples": len(stream),
        "first_event_timestamp_ns": times[0],
        "last_event_timestamp_ns": times[-1],
        "observed_mean_rate_hz": (len(times) - 1) * 1e9 / (times[-1] - times[0]) if periods else None,
        "period_ns_min": min(periods) if periods else None,
        "period_ns_median": statistics.median(periods) if periods else None,
        "period_ns_max": max(periods) if periods else None,
        "gap_threshold_ns": 30_000_000,
        "gaps_over_threshold": sum(period > 30_000_000 for period in periods),
        "missing_value_count_v0_through_v5": [sum(sample.values[i] is None for sample in stream) for i in range(6)],
    }


def _nearest(stream: list[Sample], times: list[int], timestamp: int, tolerance_ns: int) -> Sample | None:
    index = bisect_left(times, timestamp)
    candidates = stream[max(0, index - 1):index + 1]
    if not candidates:
        return None
    # A tie selects the earlier source event, deterministically.
    nearest = min(candidates, key=lambda sample: (abs(sample.timestamp_ns - timestamp), sample.timestamp_ns))
    return nearest if abs(nearest.timestamp_ns - timestamp) <= tolerance_ns else None


def _seconds(epoch_ns: int) -> str:
    return f"{epoch_ns // 1_000_000_000}.{epoch_ns % 1_000_000_000:09d}"


def export(raw_csv: Path, metadata_json: Path, output_csv: Path, *,
           allow_unvalidated_axes: bool = False, tolerance_ms: Decimal = Decimal("20")) -> dict:
    """Create CSV and *.compat.json exclusively; never change or overwrite source files."""
    if not allow_unvalidated_axes:
        raise ExportError("Explicit --allow-unvalidated-axes acknowledgement is required; see scientific limitations")
    if not isinstance(tolerance_ms, Decimal):
        tolerance_ms = Decimal(str(tolerance_ms))
    nanoseconds = tolerance_ms * 1_000_000
    if not nanoseconds.is_finite() or nanoseconds < 0 or nanoseconds != nanoseconds.to_integral_value():
        raise ExportError("Tolerance must be nonnegative and representable as whole nanoseconds")
    tolerance_ns = int(nanoseconds)
    raw_csv, metadata_json, output_csv = Path(raw_csv), Path(metadata_json), Path(output_csv)
    sidecar = output_csv.with_suffix(".compat.json")
    if output_csv.resolve() == sidecar.resolve():
        raise ExportError("Output CSV must not have the .compat.json suffix")
    sources = {raw_csv.resolve(), metadata_json.resolve()}
    if output_csv.resolve() in sources or sidecar.resolve() in sources:
        raise ExportError("An output path aliases a source file")
    if output_csv.exists() or sidecar.exists():
        raise ExportError("Refusing to overwrite an existing CSV or compatibility sidecar")
    streams = read_native(raw_csv)
    epoch_ms, elapsed_ns = read_anchor(metadata_json)
    anchors = streams[10]
    epoch_offset_ns = epoch_ms * 1_000_000 - elapsed_ns
    if epoch_offset_ns + anchors[0].timestamp_ns <= 0:
        raise ExportError("Clock anchor produces a nonpositive Unix timestamp")
    times = {sensor: [sample.timestamp_ns for sample in stream] for sensor, stream in streams.items()}
    joined = {}
    for sensor in EXPORT_TYPES:
        joined[sensor] = {
            "source_sensor_type": sensor,
            "source_sensor_name": SENSOR_NAMES[sensor],
            "matched_rows": 0, "missing_or_stale_rows": 0,
            "missing_axis_values": [0, 0, 0],
            "delta_ns_min": None, "delta_ns_max": None,
            "maximum_absolute_delta_ns": 0,
            "source_samples_reused": 0,
        }
    used: dict[int, set[int]] = {sensor: set() for sensor in EXPORT_TYPES}
    rows = []
    for anchor in anchors:
        cells = {}
        for sensor in EXPORT_TYPES:
            sample = anchor if sensor == 10 else _nearest(
                streams.get(sensor, []), times.get(sensor, []), anchor.timestamp_ns, tolerance_ns)
            audit = joined[sensor]
            if sample is None:
                audit["missing_or_stale_rows"] += 1
                audit["missing_axis_values"] = [count + 1 for count in audit["missing_axis_values"]]
                cells[sensor] = ["", "", ""]
                continue
            delta = sample.timestamp_ns - anchor.timestamp_ns
            audit["matched_rows"] += 1
            audit["delta_ns_min"] = delta if audit["delta_ns_min"] is None else min(delta, audit["delta_ns_min"])
            audit["delta_ns_max"] = delta if audit["delta_ns_max"] is None else max(delta, audit["delta_ns_max"])
            audit["maximum_absolute_delta_ns"] = max(abs(delta), audit["maximum_absolute_delta_ns"])
            audit["source_samples_reused"] += int(sample.timestamp_ns in used[sensor])
            used[sensor].add(sample.timestamp_ns)
            converted = []
            for axis, value in enumerate(sample.values[:3]):
                if value is None:
                    audit["missing_axis_values"][axis] += 1
                    converted.append("")
                else:
                    converted.append(str(value / STANDARD_GRAVITY if sensor in (10, 9) else value))
            cells[sensor] = converted
        rows.append([_seconds(epoch_offset_ns + anchor.timestamp_ns)] + cells[10] + cells[4]
                    + cells[2] + ["", "", ""] + cells[9])
    report = {
        "schema": "apple_column_unit_only_export_v1",
        "scientific_status": "UNVALIDATED_ANDROID_AXES_NOT_APPLE_EQUIVALENT",
        "acknowledgement": "--allow-unvalidated-axes",
        "limitations": LIMITATIONS,
        "source_csv": {"path": str(raw_csv.resolve()), "sha256": _sha256(raw_csv)},
        "source_metadata": {"path": str(metadata_json.resolve()), "sha256": _sha256(metadata_json)},
        "output": {"path": str(output_csv.resolve()), "rows": len(rows), "headers": APPLE_HEADERS},
        "clock_mapping": {
            "clock_anchor": {"epoch_ms": epoch_ms, "elapsed_ns": elapsed_ns},
            "formula": "Unix timestamp seconds = (epoch_ms*1000000 + event_timestamp_ns - elapsed_ns)/1000000000",
            "precision": "Integer nanosecond arithmetic; nine decimal places, not a claim of clock accuracy",
            "synchronization_verified": False,
        },
        "join": {
            "anchor_sensor_type": 10, "resampling": False,
            "method": "Nearest source event within inclusive tolerance; earlier event wins ties",
            "tolerance_ns": tolerance_ns,
            "delta_definition": "matched source event_timestamp_ns minus anchor event_timestamp_ns",
            "per_sensor": {str(sensor): joined[sensor] for sensor in EXPORT_TYPES},
        },
        "conversions": {
            "linear_acceleration_and_gravity": "Native m/s^2 divided by exactly 9.80665 to G; native sign retained",
            "gyroscope": "Native rad/s, unchanged", "magnetic_field": "Native microtesla, unchanged",
            "attitude": "Blank; neither rotation vector type is mapped to Apple Euler angles",
            "axes": "Native Android device coordinate system; no rotation or sign remapping",
        },
        "source_sensor_statistics": {
            str(sensor): {"name": SENSOR_NAMES.get(sensor, "OTHER_ANDROID_SENSOR"), **_sensor_statistics(stream)}
            for sensor, stream in sorted(streams.items())
        },
    }
    created = []
    try:
        # Exclusive opens protect both outputs even if another exporter starts concurrently.
        with output_csv.open("x", newline="", encoding="utf-8") as handle:
            created.append(output_csv)
            with sidecar.open("x", encoding="utf-8") as metadata_handle:
                created.append(sidecar)
                writer = csv.writer(handle)
                writer.writerow(APPLE_HEADERS)
                writer.writerows(rows)
                json.dump(report, metadata_handle, indent=2, allow_nan=False)
                metadata_handle.write("\n")
    except BaseException:
        for path in created:
            path.unlink(missing_ok=True)
        raise
    return report


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("raw_csv", type=Path)
    parser.add_argument("metadata_json", type=Path)
    parser.add_argument("output_csv", type=Path)
    parser.add_argument("--allow-unvalidated-axes", action="store_true",
                        help="Acknowledge that unit-converted native axes are not Apple-equivalent")
    parser.add_argument("--tolerance-ms", type=Decimal, default=Decimal("20"),
                        help="Inclusive nearest-source-event tolerance (default: 20 ms)")
    args = parser.parse_args(argv)
    try:
        report = export(args.raw_csv, args.metadata_json, args.output_csv,
                        allow_unvalidated_axes=args.allow_unvalidated_axes,
                        tolerance_ms=args.tolerance_ms)
    except (OSError, ValueError, InvalidOperation) as error:
        parser.exit(2, f"Export refused: {error}\n")
    print(f"Exported {report['output']['rows']} rows. UNVALIDATED ANDROID AXES; Apple attitude columns are blank.")
    print(f"Read scientific limitations: {args.output_csv.with_suffix('.compat.json')}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
