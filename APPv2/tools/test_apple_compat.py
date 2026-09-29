"""Synthetic contract tests; no research recordings are copied or modified."""

import csv
from decimal import Decimal
import json
from pathlib import Path
import tempfile
import unittest

from apple_compat import APPLE_HEADERS, RAW_HEADERS, ExportError, export


class AppleCompatibilityTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.raw = self.root / "motion_native.csv"
        self.metadata = self.root / "metadata.json"
        self.output = self.root / "motion_compat.csv"
        self.metadata.write_text(json.dumps({
            "clock_anchor": {"epoch_ms": 1_700_000_000_123, "elapsed_ns": 1_000_000_000}
        }))

    @staticmethod
    def row(sensor, timestamp, values=("1", "2", "3"), arrival=None):
        return [sensor, timestamp, timestamp + 1_000 if arrival is None else arrival, 3,
                *values, *([""] * (6 - len(values)))]

    def write_rows(self, rows, headers=RAW_HEADERS):
        with self.raw.open("w", newline="") as handle:
            writer = csv.writer(handle)
            writer.writerow(headers)
            writer.writerows(rows)

    def run_export(self, **kwargs):
        return export(self.raw, self.metadata, self.output, allow_unvalidated_axes=True, **kwargs)

    def read_output(self):
        with self.output.open(newline="") as handle:
            reader = csv.DictReader(handle)
            self.assertEqual(reader.fieldnames, APPLE_HEADERS)
            return list(reader)

    def assert_no_outputs(self):
        self.assertFalse(self.output.exists())
        self.assertFalse(self.output.with_suffix(".compat.json").exists())

    def test_exact_headers_units_and_native_signs(self):
        self.write_rows([
            self.row(10, 1_000_000_000, ("9.80665", "-19.61330", "0")),
            self.row(4, 1_000_000_000, ("1.5", "-2.5", "0")),
            self.row(2, 1_000_000_000, ("20", "-30", "40")),
            self.row(9, 1_000_000_000, ("0", "0", "9.80665")),
            self.row(11, 1_000_000_000, ("0", "0", "0", "1", "0")),
        ])
        original = self.raw.read_bytes()
        report = self.run_export()
        row = self.read_output()[0]
        self.assertEqual(row["accel_x(G)"], "1")
        self.assertEqual(row["accel_y(G)"], "-2")
        self.assertEqual(row["gyro_y(rad/s)"], "-2.5")
        self.assertEqual(row["mag_z(uT)"], "40")
        self.assertEqual(row["gravity_z(G)"], "1")  # Deliberately not Apple-sign corrected.
        self.assertEqual(row["timestamp"], "1700000000.123000000")
        for field in APPLE_HEADERS[10:13]:
            self.assertEqual(row[field], "")
        self.assertEqual(self.raw.read_bytes(), original)
        sidecar = json.loads(self.output.with_suffix(".compat.json").read_text())
        self.assertEqual(sidecar, report)
        self.assertIn("NOT_APPLE_EQUIVALENT", report["scientific_status"])
        self.assertFalse(report["clock_mapping"]["synchronization_verified"])

    def test_native_event_grid_is_not_resampled(self):
        self.write_rows([
            self.row(10, 1_000_000_001),
            self.row(10, 1_011_000_002),
            self.row(10, 1_097_000_003),
        ])
        report = self.run_export()
        rows = self.read_output()
        self.assertEqual([row["timestamp"] for row in rows], [
            "1700000000.123000001", "1700000000.134000002", "1700000000.220000003",
        ])
        self.assertFalse(report["join"]["resampling"])
        stats = report["source_sensor_statistics"]["10"]
        self.assertEqual(stats["samples"], 3)
        self.assertEqual(stats["gaps_over_threshold"], 1)
        self.assertAlmostEqual(stats["observed_mean_rate_hz"], 2e9 / 97_000_002)

    def test_nearest_tie_selects_earlier_and_can_reuse_samples(self):
        self.write_rows([
            self.row(10, 1_000_000_000), self.row(4, 990_000_000, ("7", "8", "9")),
            self.row(10, 1_001_000_000), self.row(4, 1_010_000_000, ("4", "5", "6")),
            self.row(10, 1_002_000_000),
        ])
        report = self.run_export()
        rows = self.read_output()
        self.assertEqual([row["gyro_x(rad/s)"] for row in rows], ["7", "4", "4"])
        gyro = report["join"]["per_sensor"]["4"]
        self.assertEqual(gyro["source_samples_reused"], 1)
        self.assertEqual(gyro["delta_ns_min"], -10_000_000)
        self.assertEqual(gyro["delta_ns_max"], 9_000_000)

    def test_tolerance_is_inclusive_missing_and_stale_are_blank(self):
        self.write_rows([
            self.row(10, 1_000_000_000, ("", "9.80665", "")),
            self.row(4, 1_020_000_000, ("1", "", "3")),
            self.row(2, 1_020_000_001),
        ])
        report = self.run_export()
        row = self.read_output()[0]
        self.assertEqual(row["gyro_x(rad/s)"], "1")
        for field in ["accel_x(G)", "accel_z(G)", "gyro_y(rad/s)", "mag_x(uT)", "gravity_z(G)"]:
            self.assertEqual(row[field], "")
        joins = report["join"]["per_sensor"]
        self.assertEqual(joins["2"]["missing_or_stale_rows"], 1)
        self.assertEqual(joins["4"]["missing_axis_values"], [0, 1, 0])
        self.assertEqual(joins["9"]["missing_axis_values"], [1, 1, 1])

    def test_zero_tolerance_requires_same_native_timestamp(self):
        self.write_rows([self.row(10, 1_000_000_000), self.row(4, 1_000_000_001)])
        self.run_export(tolerance_ms=Decimal("0"))
        self.assertEqual(self.read_output()[0]["gyro_x(rad/s)"], "")

    def test_explicit_acknowledgement_is_required(self):
        self.write_rows([self.row(10, 1_000_000_000)])
        with self.assertRaisesRegex(ExportError, "acknowledgement"):
            export(self.raw, self.metadata, self.output)
        self.assert_no_outputs()

    def test_clock_anchor_is_required_and_strict(self):
        self.write_rows([self.row(10, 1_000_000_000)])
        for bad in [{}, {"clock_anchor": {}}, {"clock_anchor": {"epoch_ms": True, "elapsed_ns": 1}},
                    {"clock_anchor": {"epoch_ms": 1.5, "elapsed_ns": 1}}]:
            with self.subTest(metadata=bad):
                self.metadata.write_text(json.dumps(bad))
                with self.assertRaises(ExportError):
                    self.run_export()
                self.assert_no_outputs()

    def test_bad_timestamps_are_rejected_without_outputs(self):
        cases = [
            [self.row(10, 1_000_000_000), self.row(10, 1_000_000_000)],
            [self.row(10, 1_000_000_000), self.row(10, 999_999_999)],
            [self.row(10, 0)],
            [self.row(10, 1_000_000_000, arrival=999_999_999)],
        ]
        for rows in cases:
            with self.subTest(rows=rows):
                self.write_rows(rows)
                with self.assertRaises(ExportError):
                    self.run_export()
                self.assert_no_outputs()

    def test_total_acceleration_is_never_substituted(self):
        self.write_rows([self.row(1, 1_000_000_000)])
        with self.assertRaisesRegex(ExportError, "never substituted"):
            self.run_export()
        self.assert_no_outputs()

    def test_existing_outputs_and_source_aliases_are_never_overwritten(self):
        self.write_rows([self.row(10, 1_000_000_000)])
        self.output.write_text("keep csv")
        with self.assertRaises(ExportError):
            self.run_export()
        self.assertEqual(self.output.read_text(), "keep csv")
        self.output.unlink()
        sidecar = self.output.with_suffix(".compat.json")
        sidecar.write_text("keep metadata")
        with self.assertRaises(ExportError):
            self.run_export()
        self.assertEqual(sidecar.read_text(), "keep metadata")
        self.assertFalse(self.output.exists())
        with self.assertRaisesRegex(ExportError, "aliases a source"):
            export(self.raw, self.metadata, self.raw, allow_unvalidated_axes=True)

    def test_malformed_csv_and_nonfinite_values_are_rejected(self):
        for values in [("NaN", "1", "2"), ("Infinity", "1", "2"), ("bad", "1", "2")]:
            with self.subTest(values=values):
                self.write_rows([self.row(10, 1_000_000_000, values)])
                with self.assertRaises(ExportError):
                    self.run_export()
                self.assert_no_outputs()
        self.write_rows([self.row(10, 1_000_000_000)], headers=RAW_HEADERS[:-1])
        with self.assertRaises(ExportError):
            self.run_export()

    def test_invalid_tolerances_do_not_create_outputs(self):
        self.write_rows([self.row(10, 1_000_000_000)])
        for tolerance in [Decimal("-1"), Decimal("NaN"), Decimal("Infinity"), Decimal("0.0000001")]:
            with self.subTest(tolerance=tolerance):
                with self.assertRaises(ExportError):
                    self.run_export(tolerance_ms=tolerance)
                self.assert_no_outputs()


if __name__ == "__main__":
    unittest.main()
