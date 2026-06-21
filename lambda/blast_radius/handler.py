"""
Blast-Radius Calculator
========================
Computes a normalized blast-radius score B ∈ [0, 1] for a proposed AI action.

Routing thresholds :
  B < 0.3           → auto-approve, skip all guardrail layers
  0.3 ≤ B < 0.9     → Layer 1 (Bedrock Guardrail) + Layer 2 (OPA)
  B ≥ 0.9           → full pipeline + mandatory Layer 4 HITL
"""
from __future__ import annotations

import logging
import os
from typing import Any

import boto3

logger = logging.getLogger()
logger.setLevel(logging.INFO)

cw = boto3.client("cloudwatch")
METRIC_NAMESPACE = os.environ.get("METRIC_NAMESPACE", "BedrockGuardrail")

# Base scores by action type
_ACTION_BASE_SCORES: dict[str, float] = {
    "terminate_instances":       0.75,
    "delete_bucket":             0.95,
    "detach_policy":             0.70,
    "modify_security_group":     0.55,
    "update_assume_role_policy": 0.80,
    "delete_stack":              0.90,
    "update_stack":              0.40,
    "restart_service":           0.30,
    "scale_down":                0.50,
    "scale_up":                  0.20,
    "deploy_artifact":           0.35,
}


def _compute_blast_radius(action: dict) -> float:
    action_type     = action.get("type", "")
    environment     = action.get("environment", "dev")
    resource_ids    = action.get("resource_ids", [])
    iam_changes     = bool(action.get("iam_changes", False))
    network_changes = bool(action.get("network_changes", False))

    # Base score
    score = _ACTION_BASE_SCORES.get(action_type, 0.50)

    # Production multiplier
    if environment == "prod":
        score = min(score * 1.30, 1.0)

    # Resource count multiplier
    if len(resource_ids) > 10:
        score = min(score * 1.20, 1.0)
    elif len(resource_ids) > 5:
        score = min(score * 1.10, 1.0)

    # IAM or network changes are high-risk amplifiers
    if iam_changes:
        score = min(score + 0.15, 1.0)
    if network_changes:
        score = min(score + 0.10, 1.0)

    return round(score, 3)


def handler(event: dict[str, Any], context: Any) -> dict[str, Any]:
    action        = event.get("action", {})
    blast_radius  = _compute_blast_radius(action)

    # Publish routing decision metric
    if blast_radius < 0.3:
        metric = "AutoApproved"
    elif blast_radius < 0.9:
        metric = "RoutedL1L2"
    else:
        metric = "RoutedFullPipeline"

    try:
        cw.put_metric_data(Namespace=METRIC_NAMESPACE, MetricData=[{"MetricName": metric, "Value": 1.0, "Unit": "Count"}])
    except Exception as exc:
        logger.warning("put_metric failed: %s", exc)

    logger.info("Blast radius: action=%s env=%s B=%.3f → %s",
                action.get("type"), action.get("environment"), blast_radius, metric)

    return {"blast_radius": blast_radius, "routing_decision": metric}
