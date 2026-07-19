#!/usr/bin/env python3
"""Validate generated files through the installed Archinstall 4.4 parser."""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path
from typing import Any


SCHEMA_COMMIT = "3ece182d31dda7b14abd56d13abf3ff79a5717ae"


def require(condition: bool, message: str) -> None:
    if not condition:
        raise RuntimeError(message)


def load_json(path: Path) -> dict[str, Any]:
    with path.open("r", encoding="utf-8") as handle:
        value = json.load(handle)
    require(isinstance(value, dict), f"{path} must contain a JSON object")
    return value


def parse_arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--config", required=True, type=Path)
    parser.add_argument("--creds", required=True, type=Path)
    parser.add_argument("--device", required=True)
    return parser.parse_args()


def main() -> int:
    arguments = parse_arguments()
    raw_config = load_json(arguments.config)
    raw_credentials = load_json(arguments.creds)

    require(raw_config["disk_config"]["device_modifications"][0]["device"] == arguments.device,
            "selected disk differs before parsing")
    require("root_enc_password" not in raw_credentials, "root account must remain locked")

    original_argv = sys.argv
    try:
        sys.argv = [
            "archinstall",
            "--config",
            str(arguments.config),
            "--creds",
            str(arguments.creds),
            "--silent",
        ]
        from archinstall.lib.args import ArchConfigHandler

        parsed = ArchConfigHandler().config
    finally:
        sys.argv = original_argv

    roundtrip_config = json.loads(parsed.user_config_to_json())
    roundtrip_credentials = json.loads(parsed.user_credentials_to_json())
    disk_config = roundtrip_config["disk_config"]
    modification = disk_config["device_modifications"][0]
    partitions = modification["partitions"]
    root_partition = partitions[1]

    require(modification["device"] == arguments.device, "selected disk did not survive parsing")
    require([entry["name"] for entry in root_partition["btrfs"]] ==
            ["@", "@home", "@log", "@pkg", "@snapshots"],
            "five Btrfs subvolumes did not survive parsing")
    require(disk_config["disk_encryption"]["partitions"] == [root_partition["obj_id"]],
            "LUKS partition reference did not survive parsing")
    require(roundtrip_config["profile_config"]["profile"]["details"] == ["KDE Plasma"],
            "KDE profile did not survive parsing")
    require(roundtrip_config["swap"] == {"enabled": False, "algorithm": "zstd"},
            "disabled Archinstall zram did not survive parsing")
    require("root_enc_password" not in roundtrip_credentials, "root became unlocked after parsing")
    require(len(roundtrip_credentials["users"]) == 1, "user did not survive parsing")
    require(roundtrip_credentials["users"][0]["sudo"] is True, "user lost sudo after parsing")

    print(json.dumps({
        "ok": True,
        "schema_commit": SCHEMA_COMMIT,
        "device": arguments.device,
        "subvolumes": [entry["name"] for entry in root_partition["btrfs"]],
    }, sort_keys=True))
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (KeyError, RuntimeError, ValueError) as error:
        print(f"schema validation failed: {error}", file=sys.stderr)
        raise SystemExit(1) from error
