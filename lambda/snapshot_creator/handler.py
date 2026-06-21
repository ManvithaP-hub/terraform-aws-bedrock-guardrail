"""
Layer 5 – Pre-Execution S3 Snapshot Creator
============================================
Called by Step Functions immediately before any approved action executes.

Captures current AWS state to S3 so it can be restored by rollback_executor
if the CloudWatch block-rate alarm fires within the 5-minute post-execution window.
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

ec2 = boto3.client("ec2")
s3c = boto3.client("s3")
cw  = boto3.client("cloudwatch")

SNAPSHOT_BUCKET  = os.environ["SNAPSHOT_BUCKET"]
METRIC_NAMESPACE = os.environ.get("METRIC_NAMESPACE", "BedrockGuardrail")


def _put_metric(name: str) -> None:
    try:
        cw.put_metric_data(Namespace=METRIC_NAMESPACE, MetricData=[{"MetricName": name, "Value": 1.0, "Unit": "Count"}])
    except Exception as exc:
        logger.warning("put_metric failed: %s", exc)


def _capture_state() -> dict:
    state: dict = {}
    try:
        resp = ec2.describe_instances()
        state["ec2_instances"] = [
            i for r in resp.get("Reservations", []) for i in r.get("Instances", [])
        ]
    except Exception as exc:
        logger.warning("ec2 snapshot failed: %s", exc)
        state["ec2_instances"] = []
    return state


def handler(event: dict[str, Any], context: Any) -> dict[str, Any]:
    action       = event.get("action", {})
    blast_radius = event.get("br", {}).get("blast_radius", 0)
    ts           = int(time.time())
    snapshot_key = f"snapshots/{ts}-{action.get('type','unknown')}.json"

    current_state = _capture_state()

    payload = {
        "snapshot_at":  ts,
        "action":       action,
        "blast_radius": blast_radius,
        "aws_state":    current_state,
    }

    s3c.put_object(
        Bucket=SNAPSHOT_BUCKET,
        Key=snapshot_key,
        Body=json.dumps(payload, default=str),
        ContentType="application/json",
    )

    _put_metric("SnapshotCreated")
    logger.info("Snapshot written: s3://%s/%s", SNAPSHOT_BUCKET, snapshot_key)

    return {"snapshot_key": snapshot_key, "snapshot_at": ts}
