"""
Layer 4 – TTL Expiry Auto-Rejection Handler
============================================
This Lambda is the core of the "silence equals rejection" mechanism.

Trigger:  DynamoDB Streams (event source mapping in lambda.tf)
          Fires on REMOVE events from the hitl_approvals table.

Why REMOVE events include TTL deletions:
  When DynamoDB TTL expires a record, it issues a REMOVE event on the stream.
  The userIdentity field identifies the actor as the DynamoDB service itself,
  distinguishing TTL-driven removals from manual deletes.

Processing:
  1. Ignore any non-REMOVE records.
  2. Ignore any REMOVE records NOT caused by DynamoDB TTL.
  3. Recover the task_token from OldImage.
  4. Call sfn.send_task_failure — this unparks the Step Functions execution
     and routes it to the AutoRejected terminal state.

No polling.  No Lambda timer.  No CloudWatch Events rule.
The DynamoDB TTL daemon is the only clock.

Important: DynamoDB TTL deletion may lag up to ~15 minutes in practice.
  The Step Functions HeartbeatSeconds (600) in step_functions.tf provides
  a backstop for any edge-case delays.
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

sfn = boto3.client("stepfunctions")
cw  = boto3.client("cloudwatch")

METRIC_NAMESPACE = os.environ.get("METRIC_NAMESPACE", "BedrockGuardrail")

# DynamoDB TTL service identity — used to distinguish TTL-driven removals
_TTL_PRINCIPAL_ID = "dynamodb.amazonaws.com"
_TTL_IDENTITY_TYPE = "Service"


def _put_metric(name: str, value: float = 1.0) -> None:
    try:
        cw.put_metric_data(Namespace=METRIC_NAMESPACE, MetricData=[{"MetricName": name, "Value": value, "Unit": "Count"}])
    except Exception as exc:
        logger.warning("put_metric failed: %s", exc)


def _is_ttl_expiry(record: dict) -> bool:
    """
    Return True only if this REMOVE event was caused by DynamoDB TTL expiry.
    Manual deletes (e.g. hitl_callback updating to APPROVED/REJECTED then deleting)
    should NOT trigger auto-rejection.
    """
    user_identity = record.get("userIdentity", {})
    return (
        user_identity.get("type") == _TTL_IDENTITY_TYPE
        and user_identity.get("principalId") == _TTL_PRINCIPAL_ID
    )


def _get_old_image_value(old_image: dict, key: str) -> str | None:
    """Extract a string value from DynamoDB OldImage (DynamoDB JSON format)."""
    attr = old_image.get(key, {})
    return attr.get("S") or attr.get("N")  # String or Number type


def handler(event: dict[str, Any], context: Any) -> dict[str, Any]:
    processed = 0
    rejected  = 0
    skipped   = 0

    for record in event.get("Records", []):
        processed += 1

        # Only handle REMOVE events
        if record.get("eventName") != "REMOVE":
            skipped += 1
            continue

        # Only auto-reject when DynamoDB TTL caused the removal
        if not _is_ttl_expiry(record):
            logger.info("REMOVE event skipped: not a TTL expiry (manual delete or hitl_callback cleanup)")
            skipped += 1
            continue

        old_image   = record.get("dynamodb", {}).get("OldImage", {})
        approval_id = _get_old_image_value(old_image, "approval_id")
        task_token  = _get_old_image_value(old_image, "task_token")
        status      = _get_old_image_value(old_image, "status")

        if not task_token:
            logger.warning("TTL REMOVE for approval_id=%s has no task_token — cannot send failure", approval_id)
            skipped += 1
            continue

        # If a hitl_callback already resolved this (status != PENDING), skip
        # to avoid a double send_task_failure (which would error on the second call).
        if status and status != "PENDING":
            logger.info("approval_id=%s already resolved with status=%s — skipping TTL auto-reject", approval_id, status)
            skipped += 1
            continue

        # ── Auto-reject: send task failure to Step Functions ──────────────────
        # This is the "silence equals rejection" trigger.
        # The SFN execution is unparked and routed to the AutoRejected state.
        try:
            sfn.send_task_failure(
                taskToken=task_token,
                error="TTLExpiry",
                cause=f"Auto-rejected: approval window of 300 seconds expired. approval_id={approval_id}",
            )
            rejected += 1
            _put_metric("HITLAutoRejected")
            logger.info(
                "AUTO-REJECTED via TTL expiry: approval_id=%s — silence equals rejection",
                approval_id
            )
        except sfn.exceptions.TaskTimedOut:
            # SFN heartbeat timeout already fired — no action needed
            logger.warning("approval_id=%s: SFN task already timed out before TTL stream fired", approval_id)
        except sfn.exceptions.InvalidToken:
            logger.warning("approval_id=%s: task token is no longer valid (execution may have ended)", approval_id)
        except Exception as exc:
            logger.error("approval_id=%s: sfn.send_task_failure error: %s", approval_id, exc)
            raise

    logger.info("Stream batch complete: processed=%d rejected=%d skipped=%d", processed, rejected, skipped)
    return {"processed": processed, "rejected": rejected, "skipped": skipped}
