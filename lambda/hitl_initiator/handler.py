"""
Layer 4 – HITL Initiator
=========================
Called by Step Functions via .waitForTaskToken.

1. Receives the SFN task token in the payload.
2. Generates an approval_id.
3. Writes a DynamoDB record:
     { approval_id, task_token, action, blast_radius, delta_score,
       status: PENDING, ttl: now + TTL_SECONDS }
4. Publishes an SNS email with approve/reject URLs.
5. Returns immediately — Step Functions execution is PARKED.

Resolution is handled by two other Lambdas:
  hitl_callback.py    — approver clicks URL → sfn.send_task_success/failure
  ttl_expiry.py       — DynamoDB TTL fires → sfn.send_task_failure("TTLExpiry")

The TTL mechanism enforces "silence equals rejection" natively.
"""
from __future__ import annotations

import json
import logging
import os
import time
import uuid
from typing import Any

import boto3

logger = logging.getLogger()
logger.setLevel(logging.INFO)

ddb       = boto3.resource("dynamodb")
sns       = boto3.client("sns")
cw        = boto3.client("cloudwatch")

HITL_TABLE       = os.environ["HITL_TABLE"]
SNS_TOPIC_ARN    = os.environ["SNS_TOPIC_ARN"]
TTL_SECONDS      = int(os.environ.get("TTL_SECONDS", "300"))
APPROVE_URL      = os.environ["APPROVE_URL"]
REJECT_URL       = os.environ["REJECT_URL"]
METRIC_NAMESPACE = os.environ.get("METRIC_NAMESPACE", "BedrockGuardrail")


def _put_metric(name: str, value: float = 1.0) -> None:
    try:
        cw.put_metric_data(Namespace=METRIC_NAMESPACE, MetricData=[{"MetricName": name, "Value": value, "Unit": "Count"}])
    except Exception as exc:
        logger.warning("put_metric failed: %s", exc)


def handler(event: dict[str, Any], context: Any) -> dict[str, Any]:
    task_token    = event["TaskToken"]
    action        = event.get("action", {})
    blast_radius  = float(event.get("blast_radius", 0.0))
    delta_score   = float(event.get("delta_score", 0.0))

    approval_id   = str(uuid.uuid4())
    expiry_epoch  = int(time.time()) + TTL_SECONDS

    approve_url   = f"{APPROVE_URL}/{approval_id}"
    reject_url    = f"{REJECT_URL}/{approval_id}"

    # ── Write HITL record to DynamoDB ─────────────────────────────────────────
    # The TTL attribute triggers automatic record deletion at expiry_epoch.
    # That deletion fires a DynamoDB Streams REMOVE event → ttl_expiry Lambda
    # → sfn.send_task_failure.  Zero polling.  Silence equals rejection.
    table = ddb.Table(HITL_TABLE)
    table.put_item(Item={
        "approval_id":  approval_id,
        "task_token":   task_token,         # recovered by ttl_expiry and hitl_callback
        "action":       json.dumps(action, default=str),
        "blast_radius": str(blast_radius),
        "delta_score":  str(delta_score),
        "status":       "PENDING",
        "ttl":          expiry_epoch,       # DynamoDB TTL attribute — native expiry
        "created_at":   int(time.time()),
    })
    logger.info("HITL record written: approval_id=%s ttl=%d", approval_id, expiry_epoch)

    # ── Publish SNS notification ───────────────────────────────────────────────
    action_desc = action.get("description", action.get("type", "unknown action"))
    message = (
        f"GUARDRAIL APPROVAL REQUIRED\n\n"
        f"Action:        {action_desc}\n"
        f"Environment:   {action.get('environment', 'unknown')}\n"
        f"Blast Radius:  {blast_radius:.3f}  (≥ 0.9 — HIGH RISK)\n"
        f"Delta Score:   {delta_score:.4f}  (≥ 0.55 — elevated uncertainty)\n"
        f"Expires in:    {TTL_SECONDS // 60} minutes  —  silence equals REJECTION\n\n"
        f"✅ APPROVE:  {approve_url}\n"
        f"❌ REJECT:   {reject_url}\n\n"
        f"Approval ID: {approval_id}\n"
        f"If you take no action within {TTL_SECONDS} seconds, "
        f"the action will be automatically REJECTED."
    )

    sns.publish(
        TopicArn=SNS_TOPIC_ARN,
        Subject=f"[{action.get('environment','?').upper()}] HITL Approval Required — {action_desc[:60]}",
        Message=message,
    )
    logger.info("SNS approval notification sent for approval_id=%s", approval_id)
    _put_metric("HITLPending")

    # The task token is parked in Step Functions.
    # This Lambda returns immediately; the SFN execution waits.
    return {"approval_id": approval_id, "ttl": expiry_epoch}
