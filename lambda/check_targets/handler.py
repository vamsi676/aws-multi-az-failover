"""check_targets: are the instances of one ASG (= one AZ) healthy in the NLB target group?

Input:  {"target_group_arn": str, "asg_name": str}
Output: {"healthy": bool, "asg_name", "availability_zones", "instances", "targets"}
Only reads; the "wait and retry" loop lives in Step Functions.
"""

from __future__ import annotations

from typing import Any

import boto3

_clients: dict[str, Any] = {}


def client(name: str) -> Any:
    if name not in _clients:
        _clients[name] = boto3.client(name)
    return _clients[name]


def lambda_handler(event: dict[str, Any], _context: Any = None) -> dict[str, Any]:
    asg_name = event["asg_name"]
    groups = client("autoscaling").describe_auto_scaling_groups(AutoScalingGroupNames=[asg_name])[
        "AutoScalingGroups"
    ]
    if not groups:
        raise ValueError(f"Auto Scaling group not found: {asg_name}")
    group = groups[0]
    instance_ids = [i["InstanceId"] for i in group.get("Instances", [])]

    health = client("elbv2").describe_target_health(TargetGroupArn=event["target_group_arn"])
    targets = {
        d["Target"]["Id"]: d["TargetHealth"]["State"]
        for d in health["TargetHealthDescriptions"]
        if d["Target"]["Id"] in instance_ids
    }
    return {
        "healthy": any(state == "healthy" for state in targets.values()),
        "asg_name": asg_name,
        "availability_zones": group.get("AvailabilityZones", []),
        "instances": instance_ids,
        "targets": targets,
    }
