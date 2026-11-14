import urllib.error

from taskboard import meta


def test_metadata_from_imds(monkeypatch, tmp_path):
    version = tmp_path / "VERSION"
    version.write_text("deadbee\n")
    monkeypatch.setattr(meta, "VERSION_FILE", version)
    monkeypatch.setattr(meta, "_imds_token", lambda timeout: "tok")
    values = {
        "placement/availability-zone": "us-east-1b",
        "instance-id": "i-0abc",
        "instance-type": "t3.micro",
    }
    monkeypatch.setattr(meta, "_imds_get", lambda path, token, timeout: values[path])

    assert meta.load_metadata() == {
        "availability_zone": "us-east-1b",
        "instance_id": "i-0abc",
        "instance_type": "t3.micro",
        "version": "deadbee",
    }


def test_metadata_off_ec2(monkeypatch):
    def fail(timeout):
        raise urllib.error.URLError("no IMDS")

    monkeypatch.setattr(meta, "_imds_token", fail)
    result = meta.load_metadata()
    assert result["availability_zone"] == "unknown"
    assert result["instance_id"] == "local"


def test_read_version_missing_file(tmp_path):
    assert meta.read_version(tmp_path / "nope") == "dev"
