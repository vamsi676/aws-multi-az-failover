"""scale_asg: set the desired capacity of one Auto Scaling group.

Input:  {"asg_name": str, "desired": int}
Output: {"asg_name", "previous_desired", "desired", "availability_zones"}
Raises on an unknown ASG, so the state machine's Catch takes over.
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
    desired = int(event["desired"])

    autoscaling = client("autoscaling")
    groups = autoscaling.describe_auto_scaling_groups(AutoScalingGroupNames=[asg_name])[
        "AutoScalingGroups"
    ]
    if not groups:
        raise ValueError(f"Auto Scaling group not found: {asg_name}")
    group = groups[0]

    autoscaling.set_desired_capacity(
        AutoScalingGroupName=asg_name,
        DesiredCapacity=desired,
        HonorCooldown=False,
    )
    return {
        "asg_name": asg_name,
        "previous_desired": int(group["DesiredCapacity"]),
        "desired": desired,
        "availability_zones": group.get("AvailabilityZones", []),
    }
