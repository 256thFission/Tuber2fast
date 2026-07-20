import json
import tempfile
import unittest
from pathlib import Path
from unittest import mock

from DeveloperTools import device_session


def physical_ipad(identifier="device-1"):
    return {
        "identifier": identifier,
        "connectionProperties": {
            "pairingState": "paired",
            "transportType": "wired",
            "tunnelState": "connected",
        },
        "deviceProperties": {
            "bootState": "booted",
            "ddiServicesAvailable": True,
            "developerModeStatus": "enabled",
            "name": "Test iPad",
            "osVersionNumber": "26.5",
        },
        "hardwareProperties": {
            "deviceType": "iPad",
            "platform": "iOS",
            "reality": "physical",
            "udid": "hardware-udid",
        },
    }


class DeviceSessionTests(unittest.TestCase):
    def test_validation_accepts_only_ready_physical_ipad(self):
        device_session._validate_physical_ipad(physical_ipad(), "device-1")
        invalid = physical_ipad()
        invalid["hardwareProperties"]["reality"] = "simulated"
        with self.assertRaisesRegex(device_session.DeviceSessionError, "not physical"):
            device_session._validate_physical_ipad(invalid, "device-1")

    def test_inspection_requires_exact_identifier(self):
        with mock.patch.object(
            device_session,
            "_run_json",
            return_value={"result": {"devices": [physical_ipad("different-device")]}},
        ):
            with self.assertRaisesRegex(device_session.DeviceSessionError, "not currently available"):
                device_session.inspect_device("device-1")

    def test_load_rejects_nonphysical_session(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "session.json"
            path.write_text(
                json.dumps(
                    {
                        "schemaVersion": 1,
                        "deviceID": "simulated-device",
                        "deviceType": "iPad",
                        "reality": "simulated",
                    }
                )
            )
            with mock.patch.object(device_session, "SESSION_FILE", path):
                with self.assertRaisesRegex(device_session.DeviceSessionError, "not a physical iPad"):
                    device_session.load_session(validate_live=False)


class TunnelNudgeTests(unittest.TestCase):
    def test_stale_tunnel_is_nudged_once_then_passes(self):
        stale = physical_ipad()
        stale["connectionProperties"]["tunnelState"] = "disconnected"
        healthy = physical_ipad()
        responses = [
            {"result": {"devices": [stale]}},
            {"result": {"devices": [healthy]}},
        ]
        with mock.patch.object(device_session, "_run_json", side_effect=responses), \
                mock.patch.object(device_session, "_nudge_tunnel") as nudge:
            device = device_session.inspect_device("device-1")
        nudge.assert_called_once_with("device-1")
        self.assertEqual(device["connectionProperties"]["tunnelState"], "connected")

    def test_persistent_disconnect_fails_after_single_nudge(self):
        stale = physical_ipad()
        stale["connectionProperties"]["tunnelState"] = "disconnected"
        with mock.patch.object(device_session, "_run_json", return_value={"result": {"devices": [stale]}}), \
                mock.patch.object(device_session, "_nudge_tunnel") as nudge:
            with self.assertRaisesRegex(device_session.DeviceSessionError, "transport is not connected"):
                device_session.inspect_device("device-1")
        nudge.assert_called_once()

    def test_non_tunnel_failures_are_not_nudged(self):
        unbooted = physical_ipad()
        unbooted["deviceProperties"]["bootState"] = "shutdown"
        with mock.patch.object(device_session, "_run_json", return_value={"result": {"devices": [unbooted]}}), \
                mock.patch.object(device_session, "_nudge_tunnel") as nudge:
            with self.assertRaisesRegex(device_session.DeviceSessionError, "not booted"):
                device_session.inspect_device("device-1")
        nudge.assert_not_called()


class DeviceLockTests(unittest.TestCase):
    def setUp(self):
        self._directory = tempfile.TemporaryDirectory()
        self.addCleanup(self._directory.cleanup)
        self.lock_path = Path(self._directory.name) / "lock.json"
        patcher = mock.patch.object(device_session, "LOCK_FILE", self.lock_path)
        patcher.start()
        self.addCleanup(patcher.stop)

    def test_acquire_writes_owned_lock(self):
        device_session.acquire_lock(4242, "verify-scenario:test")
        lock = device_session.read_lock()
        self.assertEqual(lock["pid"], 4242)
        self.assertEqual(lock["label"], "verify-scenario:test")

    def test_acquire_rejects_live_foreign_owner(self):
        device_session.acquire_lock(4242, "other-session")
        with mock.patch.object(device_session, "_pid_alive", return_value=True):
            with self.assertRaisesRegex(device_session.DeviceSessionError, "locked by live process 4242"):
                device_session.acquire_lock(5555, "this-session")

    def test_acquire_breaks_stale_lock(self):
        device_session.acquire_lock(4242, "dead-session")
        with mock.patch.object(device_session, "_pid_alive", return_value=False):
            device_session.acquire_lock(5555, "fresh-session")
        self.assertEqual(device_session.read_lock()["pid"], 5555)

    def test_acquire_is_reentrant_for_same_pid(self):
        device_session.acquire_lock(4242, "first")
        with mock.patch.object(device_session, "_pid_alive", return_value=True):
            device_session.acquire_lock(4242, "second")
        self.assertEqual(device_session.read_lock()["label"], "second")

    def test_release_by_owner_removes_lock(self):
        device_session.acquire_lock(4242, "session")
        device_session.release_lock(4242)
        self.assertIsNone(device_session.read_lock())

    def test_release_refuses_live_foreign_lock_without_force(self):
        device_session.acquire_lock(4242, "session")
        with mock.patch.object(device_session, "_pid_alive", return_value=True):
            with self.assertRaisesRegex(device_session.DeviceSessionError, "not releasing"):
                device_session.release_lock(5555)
        device_session.release_lock(5555, force=True)
        self.assertIsNone(device_session.read_lock())


class ContenderDetectionTests(unittest.TestCase):
    def test_contender_patterns(self):
        repo = str(device_session.ROOT)
        self.assertTrue(device_session._is_contender("bash DeveloperTools/verify-scenario.sh pdf-pages"))
        self.assertTrue(device_session._is_contender(f"xcodebuild -project {repo}/TuberNotes.xcodeproj build"))
        self.assertTrue(device_session._is_contender("xcodebuild -derivedDataPath DerivedDataDevice build"))
        self.assertTrue(device_session._is_contender("xcrun devicectl device install app --device X app.app"))
        self.assertFalse(device_session._is_contender("xcodebuild -project /some/other/project build"))
        self.assertFalse(device_session._is_contender("xcrun devicectl list devices"))

    def test_guard_reports_orphan_and_clears_stale_lock(self):
        with tempfile.TemporaryDirectory() as directory:
            lock_path = Path(directory) / "lock.json"
            with mock.patch.object(device_session, "LOCK_FILE", lock_path):
                orphan = [(4432, "xcodebuild -derivedDataPath DerivedDataDevice build")]
                with mock.patch.object(device_session, "_process_table", return_value=orphan):
                    with self.assertRaisesRegex(device_session.DeviceSessionError, "active device process 4432"):
                        device_session.guard_exclusive(reclaim=False)
                # A dead owner's lock is cleared, not fatal.
                device_session.acquire_lock(4242, "dead")
                with mock.patch.object(device_session, "_pid_alive", return_value=False), \
                        mock.patch.object(device_session, "_process_table", return_value=[]):
                    messages = device_session.guard_exclusive(reclaim=False)
                self.assertTrue(any("stale device lock" in message for message in messages))
                self.assertIsNone(device_session.read_lock())


if __name__ == "__main__":
    unittest.main()
