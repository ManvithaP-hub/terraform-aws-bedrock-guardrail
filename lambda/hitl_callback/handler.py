"""
Layer 4 – HITL Callback Handler (API Gateway)
==============================================
Handles approver clicks on the approve/reject URLs embedded in the SNS email.

Route: GET /approve/{approval_id}  →  approve action
Route: GET /reject/{approval_id}   →  reject action

Processing:
  1. Read DynamoDB record by approval_id.
  2. Guard: reject if status is not PENDING (already resolved or TTL-expired).
  3. Update status to APPROVED or REJECTED.
  4. Call sfn.send_task_success (approve) or sfn.send_task_failure (reject).
  5. Return a plain-text HTML confirmation page.

Note: if the DynamoDB item is gone (TTL already fired), the action was
already auto-rejected via ttl_expiry.py — we return a friendly message.
"""
from __future__ import annotations

import json
import logging
import os
import time
from typing import Any

import boto3
from boto3.dynamodb.conditions import Attr

logger = logging.getLogger()
logger.setLevel(logging.INFO)

ddb = boto3.resource("dynamodb")
sfn = boto3.client("stepfunctions")
cw  = boto3.client("cloudwatch")

HITL_TABLE       = os.environ["HITL_TABLE"]
METRIC_NAMESPACE = os.environ.get("METRIC_NAMESPACE", "BedrockGuardrail")


def _put_metric(name: str) -> None:
    try:
        cw.put_metric_data(Namespace=METRIC_NAMESPACE, MetricData=[{"MetricName": name, "Value": 1.0, "Unit": "Count"}])
    except Exception as exc:
        logger.warning("put_metric failed: %s", exc)


def _html(title: str, body: str) -> dict:
    return {
        "statusCode": 200,
        "headers": {"Content-Type": "text/html"},
        "body": f"<html><head><title>{title}</title></head><body><h2>{title}</h2><p>{body}</p></body></html>",
    }


def handler(event: dict[str, Any], context: Any) -> dict[str, Any]:
    path        = event.get("path", "")
    path_params = event.get("pathParameters", {}) or {}
    approval_id = path_params.get("approval_id", "")

    # Determine action from path prefix
    if "/approve/" in path:
        decision = "APPROVED"
    elif "/reject/" in path:
        decision = "REJECTED"
    else:
        return _html("Bad Request", "Unknown action path.")

    if not approval_id:
        return _html("Bad Request", "Missing approval_id.")

    table = ddb.Table(HITL_TABLE)

    # ── Read current record ───────────────────────────────────────────────────
    resp = table.get_item(Key={"approval_id": approval_id})
    item = resp.get("Item")

    if not item:
        # Record is gone — either TTL expired or already processed
        logger.info("approval_id=%s not found — likely TTL-expired and auto-rejected", approval_id)
        _put_metric("HITLCallbackExpired")
        return _html(
            "Approval Window Expired",
            "This approval request has already expired or been resolved. "
            "The action was automatically rejected due to the 5-minute silence-equals-rejection policy."
        )

    if item.get("status") != "PENDING":
        existing_status = item.get("status", "UNKNOWN")
        logger.info("approval_id=%s already resolved: status=%s", approval_id, existing_status)
        return _html(
            "Already Resolved",
            f"This approval was already resolved with status: {existing_status}."
        )

    task_token = item.get("task_token")
    if not task_token:
        logger.error("approval_id=%s: task_token missing from DynamoDB item", approval_id)
        return _html("Internal Error", "Task token not found. Contact your administrator.")

    # ── Update DynamoDB status ────────────────────────────────────────────────
    # Conditional write ensures only one resolution wins (race safety)
    try:
        table.update_item(
            Key={"approval_id": approval_id},
            UpdateExpression="SET #s = :status, resolved_at = :ts",
            ConditionExpression=Attr("status").eq("PENDING"),
            ExpressionAttributeNames={"#s": "status"},
            ExpressionAttributeValues={":status": decision, ":ts": int(time.time())},
        )
    except ddb.meta.client.exceptions.ConditionalCheckFailedException:
        logger.warning("approval_id=%s: concurrent update — status already changed", approval_id)
        return _html("Already Resolved", "This approval was already resolved by another action.")

    # ── Notify Step Functions ─────────────────────────────────────────────────
    try:
        if decision == "APPROVED":
            sfn.send_task_success(
                taskToken=task_token,
                output=json.dumps({"decision": "APPROVED", "approval_id": approval_id}),
            )
            _put_metric("HITLApproved")
            logger.info("APPROVED: approval_id=%s", approval_id)
            return _html("✅ Action Approved", "The action has been approved and will proceed to execution.")
        else:
            sfn.send_task_failure(
                taskToken=task_token,
                error="ManualRejection",
                cause=f"Action manually rejected by approver. approval_id={approval_id}",
            )
            _put_metric("HITLRejected")
            logger.info("REJECTED: approval_id=%s", approval_id)
            return _html("❌ Action Rejected", "The action has been rejected. No changes will be made.")

    except sfn.exceptions.TaskTimedOut:
        logger.warning("approval_id=%s: SFN task already timed out", approval_id)
        return _html("Expired", "The approval window timed out before your response was recorded.")
    except Exception as exc:
        logger.error("SFN callback error for approval_id=%s: %s", approval_id, exc)
        return {"statusCode": 500, "body": "Internal error resolving approval."}
