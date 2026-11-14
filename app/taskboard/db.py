"""DynamoDB access for tasks. Table: partition key `id` (string)."""

from __future__ import annotations

import uuid
from datetime import UTC, datetime
from typing import Any

import boto3
from botocore.config import Config
from botocore.exceptions import BotoCoreError, ClientError

# Short timeouts so /healthz answers quickly when DynamoDB is unreachable.
_BOTO_CONFIG = Config(
    connect_timeout=2,
    read_timeout=3,
    retries={"max_attempts": 2, "mode": "standard"},
)


def _now() -> str:
    return datetime.now(UTC).isoformat(timespec="milliseconds").replace("+00:00", "Z")


def _is_condition_failure(exc: ClientError) -> bool:
    return exc.response.get("Error", {}).get("Code") == "ConditionalCheckFailedException"


class TaskStore:
    def __init__(self, table_name: str, region: str | None = None) -> None:
        session = boto3.session.Session(region_name=region)
        self.table_name = table_name
        self._client = session.client("dynamodb", config=_BOTO_CONFIG)
        self._table = session.resource("dynamodb", config=_BOTO_CONFIG).Table(table_name)

    def ping(self) -> tuple[bool, str]:
        """Cheap check that the table is reachable and ACTIVE (no read capacity used)."""
        try:
            status = self._client.describe_table(TableName=self.table_name)["Table"]["TableStatus"]
        except ClientError as exc:
            return False, exc.response.get("Error", {}).get("Code", "ClientError")
        except BotoCoreError as exc:
            return False, type(exc).__name__
        return status == "ACTIVE", status

    def list_tasks(self) -> list[dict[str, Any]]:
        items: list[dict[str, Any]] = []
        kwargs: dict[str, Any] = {}
        while True:
            resp = self._table.scan(**kwargs)
            items.extend(resp.get("Items", []))
            if "LastEvaluatedKey" not in resp:
                break
            kwargs["ExclusiveStartKey"] = resp["LastEvaluatedKey"]
        return sorted(items, key=lambda t: t.get("created_at", ""))

    def create_task(self, title: str, priority: str) -> dict[str, Any]:
        now = _now()
        item = {
            "id": str(uuid.uuid4()),
            "title": title,
            "priority": priority,
            "status": "todo",
            "created_at": now,
            "updated_at": now,
        }
        self._table.put_item(
            Item=item,
            ConditionExpression="attribute_not_exists(#pk)",
            ExpressionAttributeNames={"#pk": "id"},
        )
        return item

    def update_task(self, task_id: str, changes: dict[str, Any]) -> dict[str, Any] | None:
        """Apply changes; return the updated task, or None if it does not exist."""
        changes = {**changes, "updated_at": _now()}
        names = {"#pk": "id", **{f"#{k}": k for k in changes}}
        values = {f":{k}": v for k, v in changes.items()}
        expression = "SET " + ", ".join(f"#{k} = :{k}" for k in changes)
        try:
            resp = self._table.update_item(
                Key={"id": task_id},
                UpdateExpression=expression,
                ConditionExpression="attribute_exists(#pk)",
                ExpressionAttributeNames=names,
                ExpressionAttributeValues=values,
                ReturnValues="ALL_NEW",
            )
        except ClientError as exc:
            if _is_condition_failure(exc):
                return None
            raise
        return resp["Attributes"]

    def delete_task(self, task_id: str) -> bool:
        """Delete a task; return False if it did not exist."""
        try:
            self._table.delete_item(
                Key={"id": task_id},
                ConditionExpression="attribute_exists(#pk)",
                ExpressionAttributeNames={"#pk": "id"},
            )
        except ClientError as exc:
            if _is_condition_failure(exc):
                return False
            raise
        return True
