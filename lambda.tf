# ── OPA binary download (required for Layer 2 Lambda) ─────────────────────────
# The opa_evaluator Lambda bundles the OPA binary to evaluate Rego policies.
# This null_resource downloads it at plan/apply time on the Terraform host.
resource "null_resource" "opa_binary" {
  triggers = { opa_version = var.opa_version }

  provisioner "local-exec" {
    command = <<-EOT
      mkdir -p ${path.module}/lambda/opa_evaluator/bin
      curl -sL -o ${path.module}/lambda/opa_evaluator/bin/opa \
        https://github.com/open-policy-agent/opa/releases/download/${var.opa_version}/opa_linux_amd64_static
      chmod +x ${path.module}/lambda/opa_evaluator/bin/opa
    EOT
  }
}

# Copy the Rego policy into the OPA Lambda directory
resource "null_resource" "opa_policy_copy" {
  triggers = { policy_hash = filemd5("${path.module}/${var.opa_policy_path}") }
  provisioner "local-exec" {
    command = "cp ${path.module}/${var.opa_policy_path} ${path.module}/lambda/opa_evaluator/guardrail.rego"
  }
  depends_on = [null_resource.opa_binary]
}

# ── Lambda zip archives ───────────────────────────────────────────────────────
data "archive_file" "blast_radius" {
  type = "zip"
  source_dir = "${path.module
}/lambda/blast_radius";      output_path = "${path.module}/.terraform/zips/blast_radius.zip" }
data "archive_file" "opa_evaluator" {
  type = "zip"
  source_dir = "${path.module
}/lambda/opa_evaluator";     output_path = "${path.module}/.terraform/zips/opa_evaluator.zip";     depends_on = [null_resource.opa_policy_copy] }
data "archive_file" "confidence_delta" {
  type = "zip"
  source_dir = "${path.module
}/lambda/confidence_delta";  output_path = "${path.module}/.terraform/zips/confidence_delta.zip" }
data "archive_file" "hitl_initiator" {
  type = "zip"
  source_dir = "${path.module
}/lambda/hitl_initiator";    output_path = "${path.module}/.terraform/zips/hitl_initiator.zip" }
data "archive_file" "hitl_callback" {
  type = "zip"
  source_dir = "${path.module
}/lambda/hitl_callback";     output_path = "${path.module}/.terraform/zips/hitl_callback.zip" }
data "archive_file" "ttl_expiry" {
  type = "zip"
  source_dir = "${path.module
}/lambda/ttl_expiry";        output_path = "${path.module}/.terraform/zips/ttl_expiry.zip" }
data "archive_file" "snapshot_creator" {
  type = "zip"
  source_dir = "${path.module
}/lambda/snapshot_creator";  output_path = "${path.module}/.terraform/zips/snapshot_creator.zip" }
data "archive_file" "rollback_executor" {
  type = "zip"
  source_dir = "${path.module
}/lambda/rollback_executor"; output_path = "${path.module}/.terraform/zips/rollback_executor.zip" }

# ── CloudWatch log groups ─────────────────────────────────────────────────────
locals {
  lambda_names = {
    blast_radius      = "${local.name_prefix}-blast-radius"
    opa_evaluator     = "${local.name_prefix}-opa-evaluator"
    confidence_delta  = "${local.name_prefix}-confidence-delta"
    hitl_initiator    = "${local.name_prefix}-hitl-initiator"
    hitl_callback     = "${local.name_prefix}-hitl-callback"
    ttl_expiry        = "${local.name_prefix}-ttl-expiry"
    snapshot_creator  = "${local.name_prefix}-snapshot-creator"
    rollback_executor = "${local.name_prefix}-rollback-executor"
  }
}

resource "aws_cloudwatch_log_group" "lambdas" {
  for_each          = local.lambda_names
  name              = "/aws/lambda/${each.value}"
  retention_in_days = var.log_retention_days
  kms_key_id        = local.kms_key_arn
  tags              = local.common_tags
}

# ── Lambda helper defaults ─────────────────────────────────────────────────────
locals {
  lambda_defaults = {
    runtime     = "python3.12"
    kms_key_arn = local.kms_key_arn
    tracing     = "Active"
  }
  lambda_env_base = {
    METRIC_NAMESPACE = local.metric_namespace
    ENVIRONMENT      = var.environment
  }
}

# ── Blast-radius calculator ───────────────────────────────────────────────────
resource "aws_lambda_function" "blast_radius" {
  function_name    = local.lambda_names.blast_radius
  description      = "Computes blast-radius score B for a proposed AI action"
  role             = aws_iam_role.blast_radius.arn
  handler          = "handler.handler"
  runtime          = local.lambda_defaults.runtime
  filename         = data.archive_file.blast_radius.output_path
  source_code_hash = data.archive_file.blast_radius.output_base64sha256
  timeout          = 10
  memory_size = 256
  kms_key_arn = local.lambda_defaults.kms_key_arn
  environment { variables = local.lambda_env_base }
  tracing_config { mode = local.lambda_defaults.tracing }
  depends_on = [aws_cloudwatch_log_group.lambdas]
  tags = local.common_tags
}

# ── Layer 2 – OPA evaluator ───────────────────────────────────────────────────
resource "aws_lambda_function" "opa_evaluator" {
  function_name    = local.lambda_names.opa_evaluator
  description      = "Layer 2: OPA policy evaluation against live AWS state (boto3, no cache)"
  role             = aws_iam_role.opa_evaluator.arn
  handler          = "handler.handler"
  runtime          = local.lambda_defaults.runtime
  filename         = data.archive_file.opa_evaluator.output_path
  source_code_hash = data.archive_file.opa_evaluator.output_base64sha256
  timeout          = 30
  memory_size = 512
  kms_key_arn = local.lambda_defaults.kms_key_arn
  environment { variables = merge(local.lambda_env_base, { OPA_BINARY = "/var/task/bin/opa" }) }
  tracing_config { mode = local.lambda_defaults.tracing }
  depends_on = [aws_cloudwatch_log_group.lambdas]
  tags = local.common_tags
}

# ── Layer 3 – Confidence delta scorer ────────────────────────────────────────
resource "aws_lambda_function" "confidence_delta" {
  function_name    = local.lambda_names.confidence_delta
description      = "Layer 3: Invoke Claude 3 Haiku twice (with/without guardrail)
  compute hedging delta"
  role             = aws_iam_role.confidence_delta.arn
  handler          = "handler.handler"
  runtime          = local.lambda_defaults.runtime
  filename         = data.archive_file.confidence_delta.output_path
  source_code_hash = data.archive_file.confidence_delta.output_base64sha256
  timeout          = 60
  memory_size = 512
  kms_key_arn = local.lambda_defaults.kms_key_arn
  environment {
    variables = merge(local.lambda_env_base, {
      MODEL_ID           = var.confidence_delta_model_id
      GUARDRAIL_ID       = aws_bedrock_guardrail.main.guardrail_id
      GUARDRAIL_VERSION  = tostring(aws_bedrock_guardrail_version.main.version)
      DELTA_THRESHOLD    = tostring(var.confidence_delta_threshold)
    })
  }
  tracing_config { mode = local.lambda_defaults.tracing }
  depends_on = [aws_cloudwatch_log_group.lambdas]
  tags = local.common_tags
}

# ── Layer 4 – HITL initiator ──────────────────────────────────────────────────
resource "aws_lambda_function" "hitl_initiator" {
  function_name    = local.lambda_names.hitl_initiator
description      = "Layer 4: Write HITL record to DynamoDB (TTL=+300s)
  send SNS approve/reject email"
  role             = aws_iam_role.hitl_initiator.arn
  handler          = "handler.handler"
  runtime          = local.lambda_defaults.runtime
  filename         = data.archive_file.hitl_initiator.output_path
  source_code_hash = data.archive_file.hitl_initiator.output_base64sha256
  timeout          = 15
  memory_size = 256
  kms_key_arn = local.lambda_defaults.kms_key_arn
  environment {
    variables = merge(local.lambda_env_base, {
      HITL_TABLE      = aws_dynamodb_table.hitl_approvals.name
      SNS_TOPIC_ARN   = aws_sns_topic.hitl.arn
      TTL_SECONDS     = tostring(var.hitl_ttl_seconds)
      APPROVE_URL     = local.approve_url_base
      REJECT_URL      = local.reject_url_base
    })
  }
  tracing_config { mode = local.lambda_defaults.tracing }
  depends_on = [aws_cloudwatch_log_group.lambdas]
  tags = local.common_tags
}

# ── Layer 4 – HITL callback (API Gateway) ────────────────────────────────────
resource "aws_lambda_function" "hitl_callback" {
  function_name    = local.lambda_names.hitl_callback
description      = "Layer 4: Handle approve/reject URL clicks
  call sfn.send_task_success/failure"
  role             = aws_iam_role.hitl_callback.arn
  handler          = "handler.handler"
  runtime          = local.lambda_defaults.runtime
  filename         = data.archive_file.hitl_callback.output_path
  source_code_hash = data.archive_file.hitl_callback.output_base64sha256
  timeout          = 10
  memory_size = 256
  kms_key_arn = local.lambda_defaults.kms_key_arn
  environment {
    variables = merge(local.lambda_env_base, {
      HITL_TABLE = aws_dynamodb_table.hitl_approvals.name
    })
  }
  tracing_config { mode = local.lambda_defaults.tracing }
  depends_on = [aws_cloudwatch_log_group.lambdas]
  tags = local.common_tags
}

# ── Layer 4 – TTL expiry auto-rejection (DynamoDB Streams) ───────────────────
# This is the core of the "silence equals rejection" mechanism.
# DynamoDB TTL deletion → Stream REMOVE event → this Lambda → sfn.send_task_failure
# Zero polling. Fully native.
resource "aws_lambda_function" "ttl_expiry" {
  function_name    = local.lambda_names.ttl_expiry
  description      = "Layer 4: DynamoDB Streams handler — TTL expiry = auto-rejection (silence equals rejection)"
  role             = aws_iam_role.ttl_expiry.arn
  handler          = "handler.handler"
  runtime          = local.lambda_defaults.runtime
  filename         = data.archive_file.ttl_expiry.output_path
  source_code_hash = data.archive_file.ttl_expiry.output_base64sha256
  timeout          = 30
  memory_size = 256
  kms_key_arn = local.lambda_defaults.kms_key_arn
  environment { variables = local.lambda_env_base }
  tracing_config { mode = local.lambda_defaults.tracing }
  depends_on = [aws_cloudwatch_log_group.lambdas]
  tags = local.common_tags
}

# Wire DynamoDB Streams to the TTL expiry Lambda
resource "aws_lambda_event_source_mapping" "ttl_stream" {
  event_source_arn  = aws_dynamodb_table.hitl_approvals.stream_arn
  function_name     = aws_lambda_function.ttl_expiry.arn
  starting_position = "LATEST"
  batch_size        = 10

  filter_criteria {
    filter {
      # Only trigger on REMOVE events — inserts and updates are ignored
      pattern = jsonencode({ eventName = ["REMOVE"] })
    }
  }
}

# ── Layer 5 – Snapshot creator ────────────────────────────────────────────────
resource "aws_lambda_function" "snapshot_creator" {
  function_name    = local.lambda_names.snapshot_creator
  description      = "Layer 5: Capture S3 snapshot of current AWS state before action executes"
  role             = aws_iam_role.snapshot_creator.arn
  handler          = "handler.handler"
  runtime          = local.lambda_defaults.runtime
  filename         = data.archive_file.snapshot_creator.output_path
  source_code_hash = data.archive_file.snapshot_creator.output_base64sha256
  timeout          = 30
  memory_size = 512
  kms_key_arn = local.lambda_defaults.kms_key_arn
  environment {
    variables = merge(local.lambda_env_base, {
      SNAPSHOT_BUCKET = aws_s3_bucket.snapshots.id
    })
  }
  tracing_config { mode = local.lambda_defaults.tracing }
  depends_on = [aws_cloudwatch_log_group.lambdas]
  tags = local.common_tags
}

# ── Layer 5 – Rollback executor (CloudWatch alarm trigger) ───────────────────
resource "aws_lambda_function" "rollback_executor" {
  function_name    = local.lambda_names.rollback_executor
  description      = "Layer 5: Restore AWS state from S3 snapshot when block rate < 70%"
  role             = aws_iam_role.rollback_executor.arn
  handler          = "handler.handler"
  runtime          = local.lambda_defaults.runtime
  filename         = data.archive_file.rollback_executor.output_path
  source_code_hash = data.archive_file.rollback_executor.output_base64sha256
  timeout          = 60
  memory_size = 512
  kms_key_arn = local.lambda_defaults.kms_key_arn
  environment {
    variables = merge(local.lambda_env_base, {
      SNAPSHOT_BUCKET = aws_s3_bucket.snapshots.id
      SNS_TOPIC_ARN   = aws_sns_topic.hitl.arn
    })
  }
  tracing_config { mode = local.lambda_defaults.tracing }
  depends_on = [aws_cloudwatch_log_group.lambdas]
  tags = local.common_tags
}

# Allow CloudWatch Alarms to invoke the rollback Lambda
resource "aws_lambda_permission" "rollback_from_cw" {
  statement_id  = "AllowCloudWatchAlarm"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.rollback_executor.function_name
  principal     = "lambda.alarms.cloudwatch.amazonaws.com"
  source_arn    = aws_cloudwatch_metric_alarm.block_rate_low.arn
}
