"""
Layer 2 – OPA Live AWS State Evaluator
=======================================
Fetches current AWS state immediately before each policy evaluation.
No caching. No Config. No CloudTrail. Direct boto3 SDK calls only.

State collected per invocation:
  • ec2.describe_instances()  – filtered by environment tag
  • s3.list_buckets()
  • iam.list_roles()

Passes combined {action, aws_state} as OPA input.
Calls the bundled OPA binary to evaluate guardrail.rego.
"""
from __future__ import annotations

import json
import logging
import os
import subprocess
import time
from typing import Any

import boto3

logger = logging.getLogger()
logger.setLevel(logging.INFO)

ec2 = boto3.client("ec2")
s3  = boto3.client("s3")
iam = boto3.client("iam")
cw  = boto3.client("cloudwatch")

OPA_BINARY       = os.environ.get("OPA_BINARY", "/var/task/bin/opa")
POLICY_FILE      = "/var/task/guardrail.rego"
METRIC_NAMESPACE = os.environ.get("METRIC_NAMESPACE", "BedrockGuardrail")


def _put_metric(name: str, value: float = 1.0) -> None:
    try:
        cw.put_metric_data(Namespace=METRIC_NAMESPACE, MetricData=[{"MetricName": name, "Value": value, "Unit": "Count"}])
    except Exception as exc:
        logger.warning("put_metric failed: %s", exc)


# ── Live state fetch (no cache — each invocation fetches fresh) ──────────────

def _fetch_ec2_instances() -> list[dict]:
    """Fetch all EC2 instances. Filters by environment tag are applied in OPA."""
    paginator = ec2.get_paginator("describe_instances")
    instances = []
    for page in paginator.paginate():
        for reservation in page.get("Reservations", []):
            instances.extend(reservation.get("Instances", []))
    return instances


def _fetch_s3_buckets() -> list[dict]:
    resp = s3.list_buckets()
    return resp.get("Buckets", [])


def _fetch_iam_roles() -> list[dict]:
    paginator = iam.get_paginator("list_roles")
    roles = []
    for page in paginator.paginate():
        roles.extend(page.get("Roles", []))
    return roles


def _collect_aws_state() -> dict:
    """
    Fetch all three data sources in sequence.
    Each call is fresh — no memoisation, no module-level cache.
    Failures are logged but do not abort; OPA policy handles partial state.
    """
    state: dict[str, Any] = {}

    try:
        state["ec2_instances"] = _fetch_ec2_instances()
        logger.info("Fetched %d EC2 instances", len(state["ec2_instances"]))
    except Exception as exc:
        logger.error("ec2.describe_instances failed: %s", exc)
        state["ec2_instances"] = []

    try:
        state["s3_buckets"] = _fetch_s3_buckets()
        logger.info("Fetched %d S3 buckets", len(state["s3_buckets"]))
    except Exception as exc:
        logger.error("s3.list_buckets failed: %s", exc)
        state["s3_buckets"] = []

    try:
        state["iam_roles"] = _fetch_iam_roles()
        logger.info("Fetched %d IAM roles", len(state["iam_roles"]))
    except Exception as exc:
        logger.error("iam.list_roles failed: %s", exc)
        state["iam_roles"] = []

    return state


# ── OPA evaluation ────────────────────────────────────────────────────────────

def _evaluate_opa(opa_input: dict) -> dict:
    """
    Call OPA binary via subprocess.
    Input:  { action: {...}, aws_state: {...} }
    Output: OPA result JSON, e.g. { allow: true, violations: [] }
    """
    input_json = json.dumps(opa_input, default=str)
    result = subprocess.run(
        [OPA_BINARY, "eval",
         "--data",   POLICY_FILE,
         "--input",  "/dev/stdin",
         "--format", "json",
         "data.guardrail.policy"],
        input=input_json.encode(),
        capture_output=True,
        timeout=10,
    )

    if result.returncode != 0:
        stderr = result.stderr.decode()
        logger.error("OPA evaluation failed: %s", stderr)
        raise RuntimeError(f"OPA error: {stderr}")

    opa_output = json.loads(result.stdout)
    # OPA eval result shape: {"result": [{"expressions": [{"value": {...}}]}]}
    expressions = opa_output.get("result", [{}])[0].get("expressions", [{}])
    policy_result = expressions[0].get("value", {}) if expressions else {}
    return policy_result


# ── Handler ───────────────────────────────────────────────────────────────────

def handler(event: dict[str, Any], context: Any) -> dict[str, Any]:
    t0 = time.perf_counter()

    action = event.get("action", {})

    # 1 — Fetch live AWS state (no cache)
    aws_state = _collect_aws_state()

    # 2 — Evaluate OPA policy
    opa_input = {"action": action, "aws_state": aws_state}
    try:
        policy_result = _evaluate_opa(opa_input)
    except Exception as exc:
        logger.error("OPA evaluation error: %s", exc)
        # Fail safe: deny on error
        _put_metric("OPADenied")
        return {"allowed": False, "violations": [f"OPA error: {exc}"], "fail_safe": True}

    allowed    = bool(policy_result.get("allow", False))
    violations = policy_result.get("violations", [])

    latency_ms = (time.perf_counter() - t0) * 1000
    _put_metric("OPAAllowed" if allowed else "OPADenied")
    logger.info("OPA result: allowed=%s violations=%s latency=%.0fms", allowed, violations, latency_ms)

    return {
        "allowed":    allowed,
        "violations": violations,
        "latency_ms": round(latency_ms, 1),
    }
