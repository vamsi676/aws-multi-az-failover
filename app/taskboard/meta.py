"""Instance metadata (IMDSv2) and app version, read once at startup."""

from __future__ import annotations

import urllib.request
from pathlib import Path

IMDS_BASE = "http://169.254.169.254/latest"
# build_app.sh writes the git SHA to VERSION at the bundle root (/opt/taskboard/VERSION).
VERSION_FILE = Path(__file__).resolve().parent.parent / "VERSION"


def _imds_token(timeout: float) -> str:
    req = urllib.request.Request(
        f"{IMDS_BASE}/api/token",
        method="PUT",
        headers={"X-aws-ec2-metadata-token-ttl-seconds": "300"},
    )
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        return resp.read().decode()


def _imds_get(path: str, token: str, timeout: float) -> str:
    req = urllib.request.Request(
        f"{IMDS_BASE}/meta-data/{path}",
        headers={"X-aws-ec2-metadata-token": token},
    )
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        return resp.read().decode().strip()


def read_version(path: Path | None = None) -> str:
    try:
        return (path or VERSION_FILE).read_text().strip() or "dev"
    except OSError:
        return "dev"


def load_metadata(timeout: float = 1.0) -> dict[str, str]:
    """Return AZ, instance ID/type and version. Falls back to placeholders off EC2."""
    meta = {
        "availability_zone": "unknown",
        "instance_id": "local",
        "instance_type": "unknown",
        "version": read_version(),
    }
    try:
        token = _imds_token(timeout)
        meta["availability_zone"] = _imds_get("placement/availability-zone", token, timeout)
        meta["instance_id"] = _imds_get("instance-id", token, timeout)
        meta["instance_type"] = _imds_get("instance-type", token, timeout)
    except OSError:  # URLError, timeouts, connection refused
        pass
    return meta
