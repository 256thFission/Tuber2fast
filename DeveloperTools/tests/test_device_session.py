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


if __name__ == "__main__":
    unittest.main()
