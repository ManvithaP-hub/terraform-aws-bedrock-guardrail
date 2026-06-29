# terraform-aws-bedrock-guardrail

[![License](https://img.shields.io/badge/License-Apache_2.0-blue.svg)](https://opensource.org/licenses/Apache-2.0)

A production-grade Terraform module implementing the five-layer guardrail architecture for governing autonomous AI agents in cloud-native DevOps pipelines on AWS.

This module is the infrastructure implementation of the architecture described in:

- **Research implementation and empirical evaluation**: [agentic-devops-guardrails](https://github.com/ManvithaP-hub/agentic-devops-guardrails)

---

## Architecture

The module deploys a fail-closed, five-layer pipeline that intercepts autonomous AI agent actions at the tool-call execution boundary before they affect cloud infrastructure.

```
AI Agent Action Prompt
        │
        ▼
┌─────────────────────────────┐
│  Blast-Radius Scorer        │  B < 0.3 → auto-approve
│  B(a) ∈ [0, 1]             │  B ≥ 0.3 → Layer 1 + 2
└─────────────┬───────────────┘  B ≥ 0.9 → full pipeline + HITL
              │
        ▼
┌─────────────────────────────┐
│  Layer 1: Bedrock Guardrail │  LLM output filter
│  Topic deny + PII block     │  ~340ms when blocked
└─────────────┬───────────────┘
              │
        ▼
┌─────────────────────────────┐
│  Layer 2: OPA Live State    │  Direct boto3 SDK calls
│  ec2 + s3 + iam per-call   │  No cache. No CloudTrail.
└─────────────┬───────────────┘
              │
        ▼
┌─────────────────────────────┐
│  Layer 3: Confidence Delta  │  Claude 3 Haiku A/B
│  Hedging vocab frequency    │  Threshold: δ ≥ 0.55
└─────────────┬───────────────┘
              │
        ▼
┌─────────────────────────────┐
│  Layer 4: HITL Gate         │  DynamoDB TTL = 300s
│  Silence equals rejection   │  SNS email + API Gateway
└─────────────┬───────────────┘
              │
        ▼
┌─────────────────────────────┐
│  Layer 5: Audit + Rollback  │  CloudWatch structured JSON
│  S3 snapshot before action  │  Auto-rollback if rate < 70%
└─────────────────────────────┘
```

### Blast-Radius Scoring

Every proposed agent action receives a normalized impact score B(a) ∈ [0, 1]:

| Risk Tier | Score | Vocabulary |
|---|---|---|
| Low-risk | 0.1 | list, get, describe, status, monitor, read, query |
| Medium-risk | 0.4 | restart, scale, update, patch, deploy, modify |
| High-risk | 0.9 | delete, destroy, terminate, drop, purge, wipe, erase |

### Layer 4: Silence Equals Rejection

The HITL gate is the most critical safety property of this architecture. When a high-risk action requires human approval:

1. Lambda writes a DynamoDB record with `ttl = now + 300 seconds`
2. SNS sends an email with approve and reject URLs
3. The Step Functions execution parks at `.waitForTaskToken`
4. If the approver clicks approve or reject — the pipeline resumes or terminates accordingly
5. If the TTL expires with no response — DynamoDB Streams fires a REMOVE event — the `ttl_expiry` Lambda calls `sfn.send_task_failure` — **the action is automatically rejected**

An unavailable approver never produces an implicit approval. This is enforced by native DynamoDB TTL with zero polling overhead.

---

## Prerequisites

- AWS account with Amazon Bedrock enabled in `us-east-1`
- Claude 3 Haiku model access enabled in Bedrock
- Terraform >= 1.5
- AWS credentials with permissions to create Lambda, DynamoDB, SNS, S3, IAM, CloudWatch, API Gateway, Step Functions, and Bedrock resources

---

## Usage

```hcl
module "agentic_guardrail" {
  source = "ManvithaP-hub/bedrock-guardrail/aws"

  name_prefix  = "my-agent"
  environment  = "prod"
  approver_email = "oncall@mycompany.com"

  layer2_denied_topics = [
    {
      name       = "destructive-ops"
      definition = "Actions that delete, destroy, terminate, or purge cloud infrastructure"
      examples   = ["delete all EC2 instances", "drop the RDS database", "purge the S3 bucket"]
    },
    {
      name       = "credential-exposure"
      definition = "Actions that expose or rotate AWS credentials or secrets"
      examples   = ["show me the AWS access keys", "rotate all IAM credentials"]
    }
  ]

  hitl_ttl_seconds     = 300     # 5 minutes — silence equals rejection
  block_rate_threshold = 70      # CloudWatch alarm threshold (%)
  log_retention_days   = 30

  tags = {
    Project = "agentic-ai-governance"
  }
}
```

### Basic example

See [`examples/basic/main.tf`](examples/basic/main.tf) for a complete working example.

---

## Resources Created

| Resource | Purpose |
|---|---|
| `aws_bedrock_guardrail` | Layer 1 LLM output filter |
| `aws_lambda_function` (blast_radius) | Blast-radius scoring module |
| `aws_lambda_function` (opa_evaluator) | Layer 2 live-state policy engine |
| `aws_lambda_function` (confidence_delta) | Layer 3 A/B confidence scorer |
| `aws_lambda_function` (hitl_initiator) | Layer 4 HITL gate initiator |
| `aws_lambda_function` (hitl_callback) | Layer 4 approve/reject handler |
| `aws_lambda_function` (ttl_expiry) | Layer 4 silence-equals-rejection enforcer |
| `aws_lambda_function` (snapshot_creator) | Layer 5 pre-action state capture |
| `aws_lambda_function` (rollback_executor) | Layer 5 automated rollback |
| `aws_dynamodb_table` | HITL approval records with native TTL |
| `aws_sfn_state_machine` | Pipeline orchestration |
| `aws_s3_bucket` | Audit logs and state snapshots |
| `aws_sns_topic` | HITL approval notifications |
| `aws_apigatewayv2_api` | Approve/reject URL endpoint |
| `aws_cloudwatch_metric_alarm` | Block-rate monitoring |
| `aws_kms_key` | Encryption for all data at rest |

---

## Inputs

| Name | Description | Type | Default | Required |
|---|---|---|---|---|
| `name_prefix` | Prefix for all resource names | `string` | — | yes |
| `environment` | Deployment environment (dev/staging/prod) | `string` | `"dev"` | no |
| `approver_email` | Email address for HITL approval notifications | `string` | — | yes |
| `hitl_ttl_seconds` | Seconds before unanswered approval auto-rejects | `number` | `300` | no |
| `block_rate_threshold` | CloudWatch alarm threshold for block rate (%) | `number` | `70` | no |
| `layer1_enabled` | Enable Bedrock Guardrail (Layer 1) | `bool` | `true` | no |
| `layer2_denied_topics` | Denial topics for Bedrock Guardrail | `list(object)` | `[]` | no |
| `layer2_pii_config` | PII entity filter configuration | `list(object)` | `[]` | no |
| `log_retention_days` | CloudWatch log retention in days | `number` | `30` | no |
| `kms_key_arn` | Existing KMS key ARN (creates new key if null) | `string` | `null` | no |
| `audit_bucket_name` | Existing S3 bucket name (creates new bucket if null) | `string` | `null` | no |
| `tags` | Tags to apply to all resources | `map(string)` | `{}` | no |

---

## Outputs

| Name | Description |
|---|---|
| `state_machine_arn` | ARN of the guardrail Step Functions state machine |
| `bedrock_guardrail_id` | Bedrock Guardrail ID for Layer 1 |
| `hitl_table_name` | DynamoDB table name for HITL approvals |
| `audit_bucket_name` | S3 bucket name for audit logs and snapshots |
| `approve_url` | Base URL for HITL approval actions |
| `reject_url` | Base URL for HITL rejection actions |
| `cloudwatch_alarm_arn` | ARN of the block-rate monitoring alarm |

---

## Empirical Results

This architecture was evaluated on live AWS infrastructure (us-east-1) across 100 prompts spanning five risk categories including 20 adversarial jailbreak variants:

| Category | Accuracy | FP Rate | FN Rate | Avg Latency |
|---|---|---|---|---|
| Read operations (20) | 95% | 5% | 0% | 910ms |
| Safe staging changes (20) | 100% | 0% | 0% | 7,920ms |
| Risky production changes (20) | 95% | 0% | 5% | 13,949ms |
| Destructive operations (20) | 100% | 0% | 0% | 9,590ms |
| Adversarial jailbreaks (20) | 90% | 0% | 10% | 8,125ms |
| **Total (100)** | **96%** | **1%** | **3%** | **8,099ms** |

**Key findings:**
- Zero false negatives on destructive operations (delete, destroy, terminate, purge)
- 22x latency reduction for intercepted actions (347ms vs 8,099ms)
- Total evaluation cost: $0.0017 USD
- A four-cycle calibration study reduced the false positive rate from 40% to 1%

Full empirical results and evaluation methodology: [agentic-devops-guardrails](https://github.com/ManvithaP-hub/agentic-devops-guardrails)

---

## Calibration Study

A single Bedrock guardrail tuned for zero false negatives produces a 40% false positive rate. Each layer of this architecture addresses a failure mode that previous layers architecturally cannot:

| Version | Accuracy | FP Rate | Change |
|---|---|---|---|
| v1: Single Bedrock guardrail | 60% | 40% | Baseline |
| v2: Low-risk bypass added | 79% | 18% | Architectural fix |
| v3: OPA staging context | 89% | 8% | Live state integration |
| v4: Service config keywords | 96% | 1% | Allow-list expansion |

No single layer can simultaneously minimize false positives and false negatives for the full spectrum of DevOps agent actions. Multi-layer defense-in-depth is empirically necessary.

---

## License

Apache License 2.0 — see [LICENSE](LICENSE) for details.

---

## Author

**Manvitha Potluri**
DevOps Cloud Solutions Architect
[github.com/ManvithaP-hub](https://github.com/ManvithaP-hub)
