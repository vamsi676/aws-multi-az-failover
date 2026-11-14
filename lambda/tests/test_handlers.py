import pytest
from conftest import FakeClient, FakePaginator, load_handler

precheck = load_handler("precheck")
scale_asg = load_handler("scale_asg")
check_targets = load_handler("check_targets")

SM = "arn:aws:states:us-east-1:000000000000:stateMachine:mazf-failover"
ME = SM.replace("stateMachine", "execution") + ":me"
OTHER = SM.replace("stateMachine", "execution") + ":other"
EVENT = {
    "state_machine_arn": SM,
    "execution_arn": ME,
    "standby_asg": "mazf-asg-b",
    "codedeploy_app": "mazf-app",
    "deployment_group": "mazf-dg",
}


def asg(desired=0, instances=(), az="us-east-1b"):
    return {
        "AutoScalingGroups": [
            {
                "DesiredCapacity": desired,
                "AvailabilityZones": [az],
                "Instances": [{"InstanceId": i} for i in instances],
            }
        ]
    }


def precheck_clients(fake_clients, desired=0, running=(ME,), deployments=()):
    sfn = FakeClient()
    sfn.get_paginator = lambda _op: FakePaginator(
        [{"executions": [{"executionArn": a} for a in running]}]
    )
    return fake_clients(
        precheck,
        {
            "autoscaling": FakeClient(describe_auto_scaling_groups=asg(desired)),
            "stepfunctions": sfn,
            "codedeploy": FakeClient(list_deployments={"deployments": list(deployments)}),
        },
    )


# ---------------- precheck ----------------
def test_precheck_proceeds(fake_clients):
    precheck_clients(fake_clients)
    result = precheck.lambda_handler(EVENT)
    assert result["proceed"] is True
    assert result["checks"]["other_running_executions"] == []


def test_precheck_skips_when_standby_already_up(fake_clients):
    precheck_clients(fake_clients, desired=1)
    result = precheck.lambda_handler(EVENT)
    assert result["proceed"] is False
    assert "split-brain" in result["reason"]


def test_precheck_skips_when_other_execution_running(fake_clients):
    precheck_clients(fake_clients, running=(ME, OTHER))
    result = precheck.lambda_handler(EVENT)
    assert result["proceed"] is False
    assert OTHER in result["reason"]


def test_precheck_skips_during_deployment(fake_clients):
    clients = precheck_clients(fake_clients, deployments=("d-ABC",))
    result = precheck.lambda_handler(EVENT)
    assert result["proceed"] is False
    assert "d-ABC" in result["reason"]
    op, kwargs = clients["codedeploy"].calls[0]
    assert "InProgress" in kwargs["includeOnlyStatuses"]


def test_precheck_unknown_asg_raises(fake_clients):
    clients = precheck_clients(fake_clients)
    clients["autoscaling"].responses["describe_auto_scaling_groups"] = {"AutoScalingGroups": []}
    with pytest.raises(ValueError, match="not found"):
        precheck.lambda_handler(EVENT)


# ---------------- scale_asg ----------------
def test_scale_asg_sets_desired(fake_clients):
    clients = fake_clients(
        scale_asg,
        {
            "autoscaling": FakeClient(
                describe_auto_scaling_groups=asg(desired=0), set_desired_capacity={}
            )
        },
    )
    result = scale_asg.lambda_handler({"asg_name": "mazf-asg-b", "desired": 1})
    assert result == {
        "asg_name": "mazf-asg-b",
        "previous_desired": 0,
        "desired": 1,
        "availability_zones": ["us-east-1b"],
    }
    assert clients["autoscaling"].calls[-1] == (
        "set_desired_capacity",
        {"AutoScalingGroupName": "mazf-asg-b", "DesiredCapacity": 1, "HonorCooldown": False},
    )


def test_scale_asg_unknown_asg_raises(fake_clients):
    fake_clients(
        scale_asg,
        {"autoscaling": FakeClient(describe_auto_scaling_groups={"AutoScalingGroups": []})},
    )
    with pytest.raises(ValueError, match="not found"):
        scale_asg.lambda_handler({"asg_name": "nope", "desired": 1})


# ---------------- check_targets ----------------
def targets_clients(fake_clients, states):
    return fake_clients(
        check_targets,
        {
            "autoscaling": FakeClient(describe_auto_scaling_groups=asg(1, instances=["i-b"])),
            "elbv2": FakeClient(
                describe_target_health={
                    "TargetHealthDescriptions": [
                        {"Target": {"Id": iid}, "TargetHealth": {"State": st}}
                        for iid, st in states.items()
                    ]
                }
            ),
        },
    )


EVENT_T = {"target_group_arn": "arn:tg", "asg_name": "mazf-asg-b"}


def test_check_targets_healthy(fake_clients):
    targets_clients(fake_clients, {"i-a": "unhealthy", "i-b": "healthy"})
    result = check_targets.lambda_handler(EVENT_T)
    assert result["healthy"] is True
    assert result["targets"] == {"i-b": "healthy"}  # only the standby ASG's instance counts


def test_check_targets_not_yet_healthy(fake_clients):
    targets_clients(fake_clients, {"i-a": "healthy", "i-b": "initial"})
    assert check_targets.lambda_handler(EVENT_T)["healthy"] is False


def test_check_targets_not_registered_yet(fake_clients):
    targets_clients(fake_clients, {"i-a": "healthy"})
    result = check_targets.lambda_handler(EVENT_T)
    assert result["healthy"] is False
    assert result["targets"] == {}
