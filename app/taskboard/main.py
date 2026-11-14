"""Taskboard API + pages.

Run locally: TABLE_NAME=... uvicorn taskboard.main:app
"""

from __future__ import annotations

import os
from collections.abc import AsyncIterator
from contextlib import asynccontextmanager
from pathlib import Path
from typing import Any, Literal

from fastapi import FastAPI, HTTPException, Request, Response
from fastapi.responses import FileResponse, JSONResponse
from fastapi.staticfiles import StaticFiles
from pydantic import BaseModel, Field

from taskboard.db import TaskStore
from taskboard.meta import load_metadata

STATIC_DIR = Path(__file__).resolve().parent / "static"

Priority = Literal["low", "med", "high"]
Status = Literal["todo", "in_progress", "done"]


class TaskCreate(BaseModel):
    title: str = Field(min_length=1, max_length=200)
    priority: Priority = "med"


class TaskUpdate(BaseModel):
    title: str | None = Field(default=None, min_length=1, max_length=200)
    priority: Priority | None = None
    status: Status | None = None


def create_app(store: TaskStore | None = None, metadata: dict[str, str] | None = None) -> FastAPI:
    """Build the app. Tests inject `store` and `metadata`; on EC2 they are created at startup."""
    table_name = os.environ.get("TABLE_NAME", "mazf-tasks")
    region = os.environ.get("AWS_REGION", "us-east-1")

    @asynccontextmanager
    async def lifespan(app: FastAPI) -> AsyncIterator[None]:
        if app.state.store is None:
            app.state.store = TaskStore(table_name, region)
        if app.state.metadata is None:
            app.state.metadata = load_metadata()
        yield

    app = FastAPI(title="Taskboard", lifespan=lifespan, docs_url=None, redoc_url=None)
    app.state.store = store
    app.state.metadata = metadata

    @app.middleware("http")
    async def no_store(request: Request, call_next: Any) -> Response:
        response = await call_next(request)
        response.headers["Cache-Control"] = "no-store"
        return response

    def get_store(request: Request) -> TaskStore:
        return request.app.state.store

    @app.get("/healthz")
    def healthz(request: Request) -> JSONResponse:
        ok, detail = get_store(request).ping()
        if ok:
            return JSONResponse({"status": "ok"})
        return JSONResponse({"status": "unhealthy", "reason": detail}, status_code=503)

    @app.get("/api/meta")
    def meta(request: Request) -> dict[str, str]:
        return {
            **request.app.state.metadata,
            "table_name": get_store(request).table_name,
            "region": region,
        }

    @app.get("/api/tasks")
    def list_tasks(request: Request) -> list[dict[str, Any]]:
        return get_store(request).list_tasks()

    @app.post("/api/tasks", status_code=201)
    def create_task(body: TaskCreate, request: Request) -> dict[str, Any]:
        return get_store(request).create_task(body.title.strip(), body.priority)

    @app.patch("/api/tasks/{task_id}")
    def update_task(task_id: str, body: TaskUpdate, request: Request) -> dict[str, Any]:
        changes = body.model_dump(exclude_none=True)
        if not changes:
            raise HTTPException(status_code=400, detail="No fields to update")
        if "title" in changes:
            changes["title"] = changes["title"].strip()
        task = get_store(request).update_task(task_id, changes)
        if task is None:
            raise HTTPException(status_code=404, detail="Task not found")
        return task

    @app.delete("/api/tasks/{task_id}", status_code=204)
    def delete_task(task_id: str, request: Request) -> Response:
        if not get_store(request).delete_task(task_id):
            raise HTTPException(status_code=404, detail="Task not found")
        return Response(status_code=204)

    @app.get("/", include_in_schema=False)
    def index() -> FileResponse:
        return FileResponse(STATIC_DIR / "index.html")

    @app.get("/status", include_in_schema=False)
    def status_page() -> FileResponse:
        return FileResponse(STATIC_DIR / "status.html")

    app.mount("/static", StaticFiles(directory=STATIC_DIR), name="static")
    return app


app = create_app()
