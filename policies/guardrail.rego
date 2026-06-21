package guardrail.policy

import future.keywords.if
import future.keywords.in

# Default deny
default allow := false

# Allow if no policy violations exist
allow if {
    count(violations) == 0
}

violations[msg] {
    _prod_instance_count_too_low
    msg := "Cannot terminate instances: fewer than 3 production instances remain in live AWS state"
}

violations[msg] {
    _admin_role_targeted_by_iam_action
    msg := "Cannot modify IAM: live AWS state contains admin-privileged roles in the affected scope"
}

violations[msg] {
    _delete_bucket_has_live_data
    msg := "Cannot delete S3 bucket: bucket appears in live AWS state with data"
}

violations[msg] {
    _high_blast_prod_action
    msg := "Action type is disallowed at blast radius ≥ 0.9 in production environment"
}

# ── Rule implementations ──────────────────────────────────────────────────────

_prod_instance_count_too_low if {
    input.action.type == "terminate_instances"
    input.action.environment == "prod"
    prod_instances := [i |
        i := input.aws_state.ec2_instances[_]
        some tag in i.Tags
        tag.Key == "Environment"
        tag.Value == "prod"
        i.State.Name == "running"
    ]
    count(prod_instances) < 3
}

_admin_role_targeted_by_iam_action if {
    input.action.type in {"update_assume_role_policy", "detach_policy"}
    some role in input.aws_state.iam_roles
    contains(lower(role.RoleName), "admin")
}

_delete_bucket_has_live_data if {
    input.action.type == "delete_bucket"
    some bucket in input.aws_state.s3_buckets
    bucket.Name == input.action.parameters.bucket_name
}

_high_blast_prod_action if {
    input.action.environment == "prod"
    input.action.type in {"delete_stack", "delete_bucket", "update_assume_role_policy"}
    to_number(input.blast_radius) >= 0.9
}
