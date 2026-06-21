"""
Layer 5 – Rollback Executor
============================
Triggered by the CloudWatch block-rate alarm (monitoring.tf):
  Alarm fires when block rate < 70% in any 5-minute window.

Restores the most recent S3 snapshot of AWS state via boto3.
Publishes SNS notification with rollback status.

This function is triggered directly by CloudWatch — NOT Step Functions.
"""
from __future__ import annotations

import json
import logging
import os
import time
from typing import Any

import boto3

logger = logging.getLogger()
logger.setLevel(logging.INFO)

s3c = boto3.client("s3")
ec2 = boto3.client("ec2")
sns = boto3.client("sns")
cw  = boto3.client("cloudwatch")

SNAPSHOT_BUCKET  = os.environ["SNAPSHOT_BUCKET"]
SNS_TOPIC_ARN    = os.environ["SNS_TOPIC_ARN"]
METRIC_NAMESPACE = os.environ.get("METRIC_NAMESPACE", "BedrockGuardrail")


def _put_metric(name: str) -> None:
    try:
        cw.put_metric_data(Namespace=METRIC_NAMESPACE, MetricData=[{"MetricName": name, "Value": 1.0, "Unit": "Count"}])
    except Exception as exc:
        logger.warning("put_metric failed: %s", exc)


def _find_latest_snapshot() -> tuple[str | None, dict | None]:
    """Return (key, snapshot_dict) of the most recent snapshot in S3."""
    resp = s3c.list_objects_v2(Bucket=SNAPSHOT_BUCKET, Prefix="snapshots/")
    objects = sorted(resp.get("Contents", []), key=lambda o: o["LastModified"], reverse=True)
    if not objects:
        return None, None
    key = objects[0]["Key"]
    body = s3c.get_object(Bucket=SNAPSHOT_BUCKET, Key=key)["Body"].read()
    return key, json.loads(body)


def _restore_ec2(snapshot_instances: list[dict]) -> list[str]:
    """
    Restore EC2 instances to their snapshotted state.
    Currently: start any instances that were RUNNING in the snapshot but are now stopped.
    Extend this to cover your specific action types.
    """
    restored = []
    for inst in snapshot_instances:
        inst_id = inst.get("InstanceId")
        state   = inst.get("State", {}).get("Name", "")
        if inst_id and state == "running":
            try:
                ec2.start_instances(InstanceIds=[inst_id])
                restored.append(inst_id)
                logger.info("Restored (started) instance: %s", inst_id)
            except Exception as exc:
                logger.error("Failed to restore instance %s: %s", inst_id, exc)
    return restored


def handler(event: dict[str, Any], context: Any) -> dict[str, Any]:
    """
    CloudWatch alarm invocation event.
    The alarm triggers when block rate drops below 70% in a 5-min window.
    """
    alarm_name = event.get("alarmData", {}).get("alarmName", "unknown")
    logger.warning("ROLLBACK TRIGGERED by alarm: %s", alarm_name)
    _put_metric("RollbackTriggered")

    # 1 — Find latest snapshot
    snapshot_key, snapshot = _find_latest_snapshot()
    if not snapshot:
        logger.error("No snapshot found in s3://%s/snapshots/ — cannot roll back", SNAPSHOT_BUCKET)
        _put_metric("RollbackFailed")
        sns.publish(
            TopicArn=SNS_TOPIC_ARN,
            Subject="[GUARDRAIL] ROLLBACK FAILED — No Snapshot Available",
            Message=f"Block rate alarm '{alarm_name}' fired but no S3 snapshot was found. Manual intervention required.",
        )
        return {"status": "failed", "reason": "no_snapshot"}

    logger.info("Rolling back from snapshot: s3://%s/%s", SNAPSHOT_BUCKET, snapshot_key)
    snapshot_at = snapshot.get("snapshot_at", 0)
    action      = snapshot.get("action", {})
    aws_state   = snapshot.get("aws_state", {})

    # 2 — Restore resources from snapshot
    restored_instances = _restore_ec2(aws_state.get("ec2_instances", []))

    # 3 — Publish rollback notification
    ts = int(time.time())
    message = (
        f"GUARDRAIL AUTO-ROLLBACK EXECUTED\n\n"
        f"Trigger:           Block rate < 70% (CloudWatch alarm: {alarm_name})\n"
        f"Snapshot restored: s3://{SNAPSHOT_BUCKET}/{snapshot_key}\n"
        f"Snapshot captured: {snapshot_at} (age: {ts - snapshot_at}s)\n"
        f"Action rolled back: {action.get('description', action.get('type', 'unknown'))}\n"
        f"Restored instances: {restored_instances}\n\n"
        f"Manual review required to confirm system health."
    )
    sns.publish(
        TopicArn=SNS_TOPIC_ARN,
        Subject="[GUARDRAIL] Auto-Rollback Executed",
        Message=message,
    )

    _put_metric("RollbackSucceeded")
    logger.info("Rollback complete: restored_instances=%s", restored_instances)

    return {
        "status":              "success",
        "snapshot_key":        snapshot_key,
        "snapshot_at":         snapshot_at,
        "restored_instances":  restored_instances,
    }
