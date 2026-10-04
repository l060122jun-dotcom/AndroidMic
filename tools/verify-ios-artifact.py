"""Validate unsigned IPA packaging without executing its binary."""
import argparse
import hashlib
import plistlib
import zipfile
from pathlib import Path


def verify(path: Path) -> None:
    with zipfile.ZipFile(path) as archive:
        names = archive.namelist()
        info_paths = [name for name in names if name.startswith("Payload/")
                      and name.endswith(".app/Info.plist") and name.count("/") == 2]
        assert len(info_paths) == 1, "Expected exactly one top-level application"
        info_path = info_paths[0]
        root = info_path.removesuffix("Info.plist")
        info = plistlib.loads(archive.read(info_path))
        binary = archive.read(root + info["CFBundleExecutable"])
        assert binary[:4] == b"\xcf\xfa\xed\xfe", "Expected 64-bit Mach-O"
        assert int.from_bytes(binary[4:8], "little") == 0x0100000C, "Expected arm64 device executable"
        assert info.get("NSMicrophoneUsageDescription"), "Missing microphone permission"
        assert info.get("NSLocalNetworkUsageDescription"), "Missing local network permission"
        assert "audio" in info.get("UIBackgroundModes", []), "Missing audio background mode"
        assert root + "embedded.mobileprovision" not in names, "Unexpected provisioning profile"
        print(f"IPA: {path.name}")
        print(f"Bundle: {info['CFBundleIdentifier']}")
        print(f"Minimum iOS: {info.get('MinimumOSVersion')}")
        print("PASS: arm64 device binary, permissions, background audio, no provisioning profile")
    print(f"SHA256: {hashlib.sha256(path.read_bytes()).hexdigest()}")
    print("Packaging validation only; does not prove runtime audio compatibility or absence of ad-hoc code signature.")


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("ipa", type=Path)
    verify(parser.parse_args().ipa)
