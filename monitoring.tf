locals {
  alarm_actions = var.alarm_sns_topic_arn != null ? [var.alarm_sns_topic_arn] : []
}

# ── Layer 5 – Block-rate alarm ────────────────────────────────────────────────
# The guardrail publishes two counters per action evaluation:
#   BedrockGuardrail/<prefix>  BlockedActions  (action was blocked)
#   BedrockGuardrail/<prefix>  ApprovedActions (action was approved / executed)
#
# Block rate = BlockedActions / (BlockedActions + ApprovedActions)
# Alarm fires when rate drops BELOW 0.70 in any 5-minute window.
# This triggers automatic rollback via the rollback_executor Lambda.
resource "aws_cloudwatch_metric_alarm" "block_rate_low" {
  alarm_name          = "${local.name_prefix}-guardrail-block-rate-low"
  alarm_description   = "Guardrail block rate < 70% in 5 min — possible bypass. Triggers S3 rollback."
  comparison_operator = "LessThanThreshold"
  evaluation_periods  = 1
  threshold           = var.block_rate_alarm_threshold * 100  # alarm math expression yields 0–100

  # Math expression: block_rate_pct = blocked / (blocked + approved) * 100
  metric_query {
    id          = "block_rate_pct"
    expression  = "(blocked / (blocked + approved + 0.001)) * 100"
    label       = "Block Rate %"
    return_data = true
  }
  metric_query {
    id = "blocked"
    metric {
      namespace   = local.metric_namespace
      metric_name = "BlockedActions"
      period      = 300
      stat        = "Sum"
    }
  }
  metric_query {
    id = "approved"
    metric {
      namespace   = local.metric_namespace
      metric_name = "ApprovedActions"
      period      = 300
      stat        = "Sum"
    }
  }

  treat_missing_data = "notBreaching"

  # Alarm action: invoke the rollback executor Lambda
  alarm_actions = concat(
    local.alarm_actions,
    [aws_lambda_function.rollback_executor.arn]
  )
  ok_actions = local.alarm_actions
  tags       = local.common_tags
}

# ── HITL expiry rate alarm ─────────────────────────────────────────────────────
resource "aws_cloudwatch_metric_alarm" "hitl_expiry_spike" {
  alarm_name          = "${local.name_prefix}-hitl-expiry-spike"
  alarm_description   = "Multiple HITL windows expired without approval — possible approver unavailability"
  namespace           = local.metric_namespace
  metric_name         = "HITLAutoRejected"
  statistic           = "Sum"
  period              = 600
  evaluation_periods  = 1
  threshold           = 3
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = local.alarm_actions
  tags                = local.common_tags
}

# ── SFN execution failure alarm ────────────────────────────────────────────────
resource "aws_cloudwatch_metric_alarm" "sfn_failures" {
  alarm_name          = "${local.name_prefix}-sfn-execution-failures"
  alarm_description   = "Guardrail orchestration failures > 3 in 5 minutes"
  namespace           = "AWS/States"
  metric_name         = "ExecutionsFailed"
  dimensions          = { StateMachineArn = aws_sfn_state_machine.guardrail.arn }
  statistic           = "Sum"
  period              = 300
  evaluation_periods  = 1
  threshold           = 3
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = local.alarm_actions
  ok_actions          = local.alarm_actions
  tags                = local.common_tags
}

# ── CloudWatch Dashboard ──────────────────────────────────────────────────────
resource "aws_cloudwatch_dashboard" "guardrail" {
  dashboard_name = "${local.name_prefix}-guardrail"

  dashboard_body = jsonencode({
    widgets = [
      # Row 1: Action routing breakdown
      {
type = "metric"
        x = 0
        y = 0
        width = 8
        height = 6
        properties = {
          title  = "Action Routing by Blast Radius"
view   = "timeSeries"
          period = 60
          stat = "Sum"
          metrics = [
            [local.metric_namespace, "AutoApproved",  { label = "Auto-Approved (B<0.3)" }],
            [local.metric_namespace, "RoutedL1L2",    { label = "L1+L2 Only (0.3≤B<0.9)" }],
            [local.metric_namespace, "RoutedFullPipeline", { label = "Full Pipeline (B≥0.9)" }],
          ]
        }
      },
      # Row 1: Block rate
      {
type = "metric"
        x = 8
        y = 0
        width = 8
        height = 6
        properties = {
          title  = "Block Rate % (alarm threshold: 70%)"
view   = "timeSeries"
          period = 300
          metrics = [
            [{ id = "e1", expression = "(blocked/(blocked+approved+0.001))*100", label = "Block Rate %" }],
            [local.metric_namespace, "BlockedActions",  { id = "blocked",  visible = false }],
            [local.metric_namespace, "ApprovedActions", { id = "approved", visible = false }],
          ]
          annotations = { horizontal = [{ value = 70, label = "Rollback threshold", color = "#d62728" }] }
        }
      },
      # Row 1: HITL outcomes
      {
type = "metric"
        x = 16
        y = 0
        width = 8
        height = 6
        properties = {
          title  = "Layer 4 HITL Outcomes"
view   = "timeSeries"
          period = 60
          stat = "Sum"
          metrics = [
            [local.metric_namespace, "HITLApproved",     { label = "Approved" }],
            [local.metric_namespace, "HITLRejected",     { label = "Manually Rejected" }],
            [local.metric_namespace, "HITLAutoRejected", { label = "Auto-Rejected (TTL)" }],
          ]
        }
      },
      # Row 2: Confidence delta distribution
      {
type = "metric"
        x = 0
        y = 6
        width = 12
        height = 6
        properties = {
          title  = "Layer 3 Confidence Delta Distribution"
view   = "timeSeries"
          period = 60
          metrics = [
            [local.metric_namespace, "ConfidenceDelta", { stat = "Average", label = "Avg Delta" }],
            [local.metric_namespace, "ConfidenceDelta", { stat = "p95",     label = "p95 Delta" }],
            [local.metric_namespace, "DeltaEscalations", { stat = "Sum",   label = "Escalations (≥0.55)" }],
          ]
          annotations = { horizontal = [{ value = 0.55, label = "Escalation threshold" }] }
        }
      },
      # Row 2: Step Functions execution time
      {
type = "metric"
        x = 12
        y = 6
        width = 12
        height = 6
        properties = {
          title  = "SFN Execution Duration (ms)"
view   = "timeSeries"
          period = 60
          metrics = [
            ["AWS/States", "ExecutionTime", "StateMachineArn", aws_sfn_state_machine.guardrail.arn, { stat = "p50", label = "p50" }],
            ["AWS/States", "ExecutionTime", "StateMachineArn", aws_sfn_state_machine.guardrail.arn, { stat = "p95", label = "p95" }],
          ]
        }
      },
      # Row 3: Rollback events
      {
type = "metric"
        x = 0
        y = 12
        width = 12
        height = 6
        properties = {
          title  = "Layer 5 Rollback Events"
view   = "timeSeries"
          period = 300
          stat = "Sum"
          metrics = [
            [local.metric_namespace, "RollbackTriggered",  { label = "Triggered" }],
            [local.metric_namespace, "RollbackSucceeded",  { label = "Succeeded" }],
            [local.metric_namespace, "RollbackFailed",     { label = "Failed", color = "#d62728" }],
          ]
        }
      },
      # Row 3: OPA policy violations
      {
type = "metric"
        x = 12
        y = 12
        width = 12
        height = 6
        properties = {
          title  = "Layer 2 OPA Policy Violations"
view   = "timeSeries"
          period = 60
          stat = "Sum"
          metrics = [
            [local.metric_namespace, "OPAAllowed",  { label = "Allowed" }],
            [local.metric_namespace, "OPADenied",   { label = "Denied" }],
          ]
        }
      },
    ]
  })
}
