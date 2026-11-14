import os

import boto3
import pytest
from fastapi.testclient import TestClient
from moto import mock_aws

# Fake credentials so nothing can ever reach a real AWS account from tests.
os.environ["AWS_ACCESS_KEY_ID"] = "testing"
os.environ["AWS_SECRET_ACCESS_KEY"] = "testing"
os.environ["AWS_SESSION_TOKEN"] = "testing"
os.environ["AWS_DEFAULT_REGION"] = "us-east-1"
os.environ.pop("AWS_PROFILE", None)

from taskboard.db import TaskStore  # noqa: E402
from taskboard.main import create_app  # noqa: E402

TABLE = "test-tasks"
META = {
    "availability_zone": "us-east-1a",
    "instance_id": "i-0123456789abcdef0",
    "instance_type": "t3.micro",
    "version": "abc1234",
}


@pytest.fixture
def aws():
    with mock_aws():
        yield


@pytest.fixture
def store(aws):
    boto3.client("dynamodb", region_name="us-east-1").create_table(
        TableName=TABLE,
        KeySchema=[{"AttributeName": "id", "KeyType": "HASH"}],
        AttributeDefinitions=[{"AttributeName": "id", "AttributeType": "S"}],
        BillingMode="PAY_PER_REQUEST",
    )
    return TaskStore(TABLE, "us-east-1")


@pytest.fixture
def client(store):
    return TestClient(create_app(store=store, metadata=dict(META)))
