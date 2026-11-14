from fastapi.testclient import TestClient

from taskboard.db import TaskStore
from taskboard.main import create_app


def test_create_and_list(client):
    r = client.post("/api/tasks", json={"title": "  Write tests  ", "priority": "high"})
    assert r.status_code == 201
    task = r.json()
    assert task["title"] == "Write tests"
    assert task["priority"] == "high"
    assert task["status"] == "todo"
    assert task["created_at"] == task["updated_at"]

    tasks = client.get("/api/tasks").json()
    assert [t["id"] for t in tasks] == [task["id"]]


def test_default_priority_is_med(client):
    assert client.post("/api/tasks", json={"title": "x"}).json()["priority"] == "med"


def test_list_sorted_by_created_at(client):
    ids = [client.post("/api/tasks", json={"title": f"t{i}"}).json()["id"] for i in range(3)]
    assert [t["id"] for t in client.get("/api/tasks").json()] == ids


def test_patch_status_and_title(client):
    task = client.post("/api/tasks", json={"title": "Move me"}).json()
    r = client.patch(f"/api/tasks/{task['id']}", json={"status": "in_progress", "title": "Moved"})
    assert r.status_code == 200
    updated = r.json()
    assert updated["status"] == "in_progress"
    assert updated["title"] == "Moved"
    assert updated["created_at"] == task["created_at"]


def test_patch_unknown_task_is_404(client):
    assert client.patch("/api/tasks/nope", json={"status": "done"}).status_code == 404


def test_patch_without_fields_is_400(client):
    task = client.post("/api/tasks", json={"title": "x"}).json()
    assert client.patch(f"/api/tasks/{task['id']}", json={}).status_code == 400


def test_delete(client):
    task = client.post("/api/tasks", json={"title": "Delete me"}).json()
    assert client.delete(f"/api/tasks/{task['id']}").status_code == 204
    assert client.get("/api/tasks").json() == []
    assert client.delete(f"/api/tasks/{task['id']}").status_code == 404


def test_validation_errors(client):
    assert client.post("/api/tasks", json={"title": ""}).status_code == 422
    assert client.post("/api/tasks", json={"title": "x", "priority": "urgent"}).status_code == 422
    assert client.post("/api/tasks", json={"title": "x" * 201}).status_code == 422
    task = client.post("/api/tasks", json={"title": "x"}).json()
    assert client.patch(f"/api/tasks/{task['id']}", json={"status": "blocked"}).status_code == 422


def test_cache_control_no_store_everywhere(client):
    for path in ("/api/tasks", "/api/meta", "/healthz", "/", "/status"):
        assert client.get(path).headers["cache-control"] == "no-store", path


def test_meta(client):
    meta = client.get("/api/meta").json()
    assert meta["availability_zone"] == "us-east-1a"
    assert meta["instance_id"].startswith("i-")
    assert meta["version"] == "abc1234"
    assert meta["table_name"] == "test-tasks"


def test_healthz_ok(client):
    r = client.get("/healthz")
    assert r.status_code == 200
    assert r.json() == {"status": "ok"}


def test_healthz_503_when_table_missing(aws):
    app = create_app(store=TaskStore("missing-table", "us-east-1"), metadata={})
    r = TestClient(app).get("/healthz")
    assert r.status_code == 503
    assert r.json()["status"] == "unhealthy"
    assert r.json()["reason"] == "ResourceNotFoundException"


def test_pages_served(client):
    assert "Taskboard" in client.get("/").text
    assert "Last downtime (RTO)" in client.get("/status").text
    assert client.get("/static/style.css").status_code == 200
