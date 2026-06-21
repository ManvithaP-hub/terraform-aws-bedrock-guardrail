provider "aws" { region = "us-east-1" }

module "guardrail" {
  source = "../../"

  name_prefix         = "myapp"
  environment         = "prod"
  hitl_approver_email = "ops-team@example.com"

  # Blast-radius defaults match architecture spec exactly — only override if experimenting
  blast_radius_auto_approve_threshold = 0.3
  blast_radius_hitl_threshold         = 0.9

  # Layer 3 — Claude 3 Haiku, threshold 0.55 (architecture defaults)
  confidence_delta_model_id  = "anthropic.claude-3-haiku-20240307-v1:0"
  confidence_delta_threshold = 0.55

  # Layer 4 — 5-minute TTL; silence equals rejection
  hitl_ttl_seconds = 300

  # Layer 5 — rollback when block rate drops below 70%
  block_rate_alarm_threshold = 0.70

  alarm_sns_topic_arn = aws_sns_topic.ops.arn
}

resource "aws_sns_topic" "ops" { name = "myapp-prod-ops-alerts" }

output "invoke_arn" { value = module.guardrail.state_machine_arn }
