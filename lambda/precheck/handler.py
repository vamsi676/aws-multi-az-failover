"""Precheck: decide whether a failover/failback may start. Never changes anything.

Input (from Step Functions):
    state_machine_arn  $$.StateMachine.Id (not an env var: avoids a circular dependency)
    execution_arn      $$.Execution.Id (this run, excluded from the RUNNING check)
    standby_asg        ASG that would be scaled up
    codedeploy_app, deployment_group

Output: {"proceed": bool, "reason": str, "checks": {...}}
"""

from __future__ import annotations

from typing import Any

import boto3

# CodeDeploy statuses that mean "a deployment is still going on".
ACTIVE_DEPLOYMENT_STATUSES = ["Created", "Queued", "InProgress", "Baking", "Ready"]

_clients: dict[str, Any] = {}


def client(name: str) -> Any:
    if name not in _clients:
        _clients[name] = boto3.client(name)
    return _clients[name]


def _standby_desired(asg_name: str) -> int:
    groups = client("autoscaling").describe_auto_scaling_groups(AutoScalingGroupNames=[asg_name])[
        "AutoScalingGroups"
    ]
    if not groups:
        raise ValueError(f"Auto Scaling group not found: {asg_name}")
    return int(groups[0]["DesiredCapacity"])


def _other_running_executions(state_machine_arn: str, execution_arn: str) -> list[str]:
    paginator = client("stepfunctions").get_paginator("list_executions")
    running = []
    for page in paginator.paginate(stateMachineArn=state_machine_arn, statusFilter="RUNNING"):
        running += [e["executionArn"] for e in page["executions"]]
    return [arn for arn in running if arn != execution_arn]


def _active_deployments(app: str, group: str) -> list[str]:
    resp = client("codedeploy").list_deployments(
        applicationName=app,
        deploymentGroupName=group,
        includeOnlyStatuses=ACTIVE_DEPLOYMENT_STATUSES,
    )
    return resp.get("deployments", [])


def lambda_handler(event: dict[str, Any], _context: Any = None) -> dict[str, Any]:
    standby_desired = _standby_desired(event["standby_asg"])
    others = _other_running_executions(event["state_machine_arn"], event["execution_arn"])
    deployments = _active_deployments(event["codedeploy_app"], event["deployment_group"])

    checks = {
        "standby_asg": event["standby_asg"],
        "standby_desired": standby_desired,
        "other_running_executions": others,
        "active_deployments": deployments,
    }

    if standby_desired > 0:
        reason = (
            f"Standby ASG {event['standby_asg']} already has desired capacity "
            f"{standby_desired}: traffic is probably already on the standby AZ (split-brain guard)."
        )
    elif others:
        reason = f"Another execution of this state machine is RUNNING: {others[0]}"
    elif deployments:
        reason = (
            f"CodeDeploy deployment {deployments[0]} is in progress: a bad release would also "
            "reach the standby AZ, so failing over would not help."
        )
    else:
        return {"proceed": True, "reason": "All prechecks passed", "checks": checks}

    return {"proceed": False, "reason": reason, "checks": checks}
