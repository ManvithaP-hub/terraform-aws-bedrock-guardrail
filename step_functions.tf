resource "aws_cloudwatch_log_group" "sfn" {
  name              = "/aws/states/${local.name_prefix}-guardrail-orchestrator"
  retention_in_days = var.log_retention_days
  kms_key_id        = local.kms_key_arn
  tags              = local.common_tags
}

# ──────────────────────────────────────────────────────────────────────────────
# Orchestration state machine
#
# Input contract:
#   {
#     "action": {
#       "type":         "terminate_instances",
#       "description":  "Terminate prod cluster nodes",
#       "resource_ids": ["i-xxx"],
#       "environment":  "prod",
#       "parameters":   {}
#     },
#     "prompt": "..."     ← natural-language description for Bedrock calls
#   }
#
# Blast-radius routing :
#   B < 0.3           → AutoApprove (skip all layers, execute immediately)
#   0.3 ≤ B < 0.9     → Layer 1 (Bedrock Guardrail) + Layer 2 (OPA)
#   B ≥ 0.9           → Layers 1 + 2 + 3 (confidence delta) + Layer 4 (HITL)
#
# Layer 4 uses .waitForTaskToken — SFN parks execution until:
#   • Approver clicks approve URL  → hitl_callback → sfn.send_task_success
#   • Approver clicks reject URL   → hitl_callback → sfn.send_task_failure
#   • DynamoDB TTL fires (300 s)   → ttl_expiry Lambda → sfn.send_task_failure
#   Silence == rejection, enforced natively with zero polling.
# ──────────────────────────────────────────────────────────────────────────────
resource "aws_sfn_state_machine" "guardrail" {
  name     = "${local.name_prefix}-guardrail-orchestrator"
  role_arn = aws_iam_role.sfn.arn
  type     = "EXPRESS"

  definition = jsonencode({
    Comment = "Five-Layer Agentic AI Guardrail – agentic AI guardrail architecture"
    StartAt = "CalculateBlastRadius"

    States = {

      # ── Blast-radius calculation ─────────────────────────────────────────────
      "CalculateBlastRadius" = {
        Type     = "Task"
        Resource = "arn:aws:states:::lambda:invoke"
        Parameters = { "FunctionName" = aws_lambda_function.blast_radius.arn, "Payload.$" = "$" }
        ResultSelector = { "blast_radius.$" = "$.Payload.blast_radius" }
        ResultPath = "$.br"
        Next       = "RouteByBlastRadius"
        Retry = [{ ErrorEquals = ["Lambda.ServiceException"], IntervalSeconds = 1, MaxAttempts = 2, BackoffRate = 2 }]
        Catch = [{ ErrorEquals = ["States.ALL"], Next = "ExecutionFailed", ResultPath = "$.error" }]
      }

      # ── Routing gate ────────────────────────────────────────────────────────
      "RouteByBlastRadius" = {
        Type = "Choice"
        Choices = [
          # B < 0.3 → auto-approve, skip all layers
          { Variable = "$.br.blast_radius", NumericLessThan = 0.3, Next = "AutoApprove" },
          # B ≥ 0.9 → full pipeline including mandatory HITL
          { Variable = "$.br.blast_radius", NumericGreaterThanEquals = 0.9, Next = "Layer1_BedrockGuardrail" },
        ]
        # 0.3 ≤ B < 0.9 → Layers 1 + 2 only
        Default = "Layer1_BedrockGuardrail"
      }

      # ── Auto-approve path (B < 0.3) ─────────────────────────────────────────
      "AutoApprove" = {
        Type = "Pass"
        Result = { auto_approved = true }
        ResultPath = "$.approval"
        Next = "SnapshotBeforeExecution"
      }

      # ── Layer 1 – Bedrock Guardrail (LLM output filter) ─────────────────────
      "Layer1_BedrockGuardrail" = {
        Type     = "Task"
        Resource = "arn:aws:states:::bedrock:invokeModel"
        Parameters = {
          ModelId             = var.confidence_delta_model_id
          GuardrailIdentifier = aws_bedrock_guardrail.main.guardrail_arn
          GuardrailVersion    = tostring(aws_bedrock_guardrail_version.main.version)
          Trace               = "ENABLED"
          Body = {
            anthropic_version = "bedrock-2023-05-31"
            max_tokens        = 512
            messages = [{
              role    = "user"
              "content.$" = "$.prompt"
            }]
          }
        }
        ResultSelector = {
          "guardrail_action.$" = "$.GuardrailAction"
          "body.$"             = "States.StringToJson($.Body)"
        }
        ResultPath = "$.layer1"
        Next       = "CheckGuardrailBlocked"
        Catch = [{ ErrorEquals = ["States.ALL"], Next = "ExecutionFailed", ResultPath = "$.error" }]
      }

      "CheckGuardrailBlocked" = {
        Type = "Choice"
        Choices = [{
          Variable      = "$.layer1.guardrail_action"
          StringEquals  = "GUARDRAIL_INTERVENED"
          Next          = "BlockedByGuardrail"
        }]
        Default = "Layer2_OPA"
      }

      "BlockedByGuardrail" = {
        Type = "Fail"
        Error = "GuardrailBlocked"
        Cause = "Layer 1 Bedrock Guardrail intervened"
      }

      # ── Layer 2 – OPA live AWS state evaluation ──────────────────────────────
      "Layer2_OPA" = {
        Type     = "Task"
        Resource = "arn:aws:states:::lambda:invoke"
        Parameters = { "FunctionName" = aws_lambda_function.opa_evaluator.arn, "Payload.$" = "$" }
        ResultSelector = {
          "allowed.$"    = "$.Payload.allowed"
          "violations.$" = "$.Payload.violations"
        }
        ResultPath = "$.layer2"
        Next       = "CheckOPAResult"
        Retry = [{ ErrorEquals = ["Lambda.ServiceException"], IntervalSeconds = 1, MaxAttempts = 2, BackoffRate = 2 }]
        Catch = [{ ErrorEquals = ["States.ALL"], Next = "ExecutionFailed", ResultPath = "$.error" }]
      }

      "CheckOPAResult" = {
        Type = "Choice"
        Choices = [
          # OPA denied → fail immediately regardless of blast radius
          { Variable = "$.layer2.allowed", BooleanEquals = false, Next = "BlockedByOPA" },
          # B ≥ 0.9 → continue to Layer 3 confidence delta
          { Variable = "$.br.blast_radius", NumericGreaterThanEquals = 0.9, Next = "Layer3_ConfidenceDelta" },
        ]
        # 0.3 ≤ B < 0.9, OPA passed → proceed to execution
        Default = "SnapshotBeforeExecution"
      }

      "BlockedByOPA" = {
        Type = "Fail"
        Error = "OPADenied"
        Cause = "Layer 2 OPA policy denied the action based on live AWS state"
      }

      # ── Layer 3 – Confidence delta scorer ────────────────────────────────────
      # Invokes Claude 3 Haiku twice: once WITH guardrail, once WITHOUT.
      # Counts hedging vocabulary in each response.
      # Delta ≥ 0.55 → escalate to HITL.
      "Layer3_ConfidenceDelta" = {
        Type     = "Task"
        Resource = "arn:aws:states:::lambda:invoke"
        Parameters = { "FunctionName" = aws_lambda_function.confidence_delta.arn, "Payload.$" = "$" }
        ResultSelector = {
          "escalate.$"    = "$.Payload.escalate"
          "delta_score.$" = "$.Payload.delta_score"
        }
        ResultPath = "$.layer3"
        Next       = "CheckDeltaThreshold"
        Retry = [{ ErrorEquals = ["Lambda.ServiceException"], IntervalSeconds = 1, MaxAttempts = 2, BackoffRate = 2 }]
        Catch = [{ ErrorEquals = ["States.ALL"], Next = "ExecutionFailed", ResultPath = "$.error" }]
      }

      "CheckDeltaThreshold" = {
        Type = "Choice"
        Choices = [{
          Variable      = "$.layer3.escalate"
          BooleanEquals = true
          Next          = "Layer4_HITL"
        }]
        Default = "SnapshotBeforeExecution"
      }

      # ── Layer 4 – HITL gate (DynamoDB TTL silence-equals-rejection) ──────────
      # .waitForTaskToken parks the execution.
      # Task token is stored in DynamoDB alongside the PENDING record.
      # Resolution paths:
      #   Approve URL clicked  → hitl_callback → sfn.send_task_success
      #   Reject URL clicked   → hitl_callback → sfn.send_task_failure("ManualRejection")
      #   TTL fires after 300s → ttl_expiry Lambda → sfn.send_task_failure("TTLExpiry")
      # HeartbeatSeconds set above TTL to ensure TTL stream fires before SFN times out.
      "Layer4_HITL" = {
        Type     = "Task"
        Resource = "arn:aws:states:::lambda:invoke.waitForTaskToken"
        Parameters = {
          "FunctionName" = aws_lambda_function.hitl_initiator.arn
          Payload = {
            "TaskToken.$"   = "$$.Task.Token"
            "action.$"      = "$.action"
            "blast_radius.$" = "$.br.blast_radius"
            "delta_score.$" = "$.layer3.delta_score"
          }
        }
        HeartbeatSeconds = 600   # safety net; primary rejection via DDB TTL Streams
        ResultPath = "$.layer4"
        Next       = "SnapshotBeforeExecution"
        Catch = [
          { ErrorEquals = ["TTLExpiry"],       Next = "AutoRejected",   ResultPath = "$.rejection" },
          { ErrorEquals = ["ManualRejection"], Next = "ManuallyRejected", ResultPath = "$.rejection" },
          { ErrorEquals = ["States.HeartbeatTimeout"], Next = "AutoRejected", ResultPath = "$.rejection" },
          { ErrorEquals = ["States.ALL"],      Next = "ExecutionFailed", ResultPath = "$.error" },
        ]
      }

      "AutoRejected" = {
        Type = "Fail"
        Error = "AutoRejected"
        Cause = "HITL window expired (300 s). Silence equals rejection."
      }

      "ManuallyRejected" = {
        Type = "Fail"
        Error = "ManuallyRejected"
        Cause = "Action rejected by human approver"
      }

      # ── Layer 5a – S3 snapshot before execution ──────────────────────────────
      "SnapshotBeforeExecution" = {
        Type     = "Task"
        Resource = "arn:aws:states:::lambda:invoke"
        Parameters = { "FunctionName" = aws_lambda_function.snapshot_creator.arn, "Payload.$" = "$" }
        ResultSelector = { "snapshot_key.$" = "$.Payload.snapshot_key" }
        ResultPath = "$.layer5"
        Next       = "ExecuteAction"
        Catch = [{ ErrorEquals = ["States.ALL"], Next = "ExecutionFailed", ResultPath = "$.error" }]
      }

      # ── Execute approved action ───────────────────────────────────────────────
      # Replace this Pass state with the actual action executor Lambda.
      # CloudWatch monitors the 5-minute post-execution window (monitoring.tf).
      "ExecuteAction" = {
        Type = "Pass"
        Parameters = {
          "status"        = "executed"
          "action.$"      = "$.action"
          "snapshot_key.$" = "$.layer5.snapshot_key"
          "blast_radius.$" = "$.br.blast_radius"
        }
        End = true
      }

      "ExecutionFailed" = {
        Type  = "Fail"
        Error = "ExecutionFailed"
        Cause = "Guardrail orchestration encountered an unrecoverable error"
      }
    }
  })

  logging_configuration {
    log_destination        = "${aws_cloudwatch_log_group.sfn.arn}:*"
    include_execution_data = false
    level                  = "ERROR"
  }

  tracing_configuration { enabled = true }
  tags = local.common_tags
}
