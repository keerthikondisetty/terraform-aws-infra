# terraform-aws-infra

[![terraform](https://github.com/keerthikondisetty/terraform-aws-infra/actions/workflows/terraform.yml/badge.svg)](https://github.com/keerthikondisetty/terraform-aws-infra/actions/workflows/terraform.yml) [![licence](https://img.shields.io/badge/licence-MIT-blue.svg)](LICENSE)

The AWS environment that runs the webhook receiver in
[devops-demo-app](https://github.com/keerthikondisetty/devops-demo-app):
a VPC across two availability zones, an application load balancer, instances in
an autoscaling group, and a Postgres database. Three modules, one environment
wiring them together.

```
              internet
                 │
          ┌──────▼──────┐   public subnets, 2 AZs
          │     ALB     │   :443 only, :80 redirects
          └──────┬──────┘
                 │  security group reference, not a CIDR
       ┌─────────▼─────────┐   private subnets
       │  ASG: 2-4 × EC2   │   no public IP, no SSH
       └─────────┬─────────┘
                 │
          ┌──────▼──────┐   private subnets
          │  RDS Postgres│  reachable from the app SG only
          └─────────────┘
```

```bash
make verify   # fmt, validate and checkov. No AWS credentials needed.
```

```
tofu validate: clean
checkov: 190 passed, 0 failed, 9 skipped with written justification
```

## The decisions worth asking me about

**Security groups reference other security groups, not CIDRs.**

```hcl
resource "aws_vpc_security_group_ingress_rule" "app_from_alb" {
  referenced_security_group_id = aws_security_group.alb.id
  from_port                    = var.app_port
}
```

The rule keeps meaning "from the load balancer" as subnets and addresses
change, and it cannot be quietly widened the way `10.0.0.0/8` can.

**The database security group has no egress rule at all.** Not a restrictive
one at all. A database has no reason to open outbound connections, and the
absence of a rule states that more clearly than any rule could.

**No SSH anywhere.** Access is SSM Session Manager: no port 22, no key pair to
leak, no bastion to patch, and every session lands in CloudTrail.

**IMDSv2 required** on the launch template. Without it, one server-side request
forgery in the application reads the instance credentials with a single GET.
It is one block of config and it closes the most common EC2 credential-theft
path outright.

**The ASG health check is `ELB`, not `EC2`.** The EC2 check only asks whether
the instance is running, so an instance whose application has wedged stays
"healthy" indefinitely and keeps receiving traffic.

**The target group health checks `/readyz`, not `/healthz`.** The load balancer
is asking whether the instance can serve traffic, which is a different question
from whether the process is alive. The app repo explains why those are two
endpoints.

**The queue stays in Postgres.** The app uses a `deliveries` table with
`SELECT ... FOR UPDATE SKIP LOCKED` rather than SQS, and this environment does
not add SQS to "fix" that.

That is the decision I would defend hardest here. A Postgres queue handles
thousands of jobs a minute, gives transactional enqueue for free, and RDS is
already in the diagram and already backed up. Adding SQS means a second
durability story, a second thing to grant IAM for, a second place to look
during an incident, and a dead-letter queue that is separate from the dead
letters the application already tracks in a table you can query with SQL.

You move to SQS when you need fan-out to several consumers, or ordering
guarantees Postgres will not give you, or throughput past what one database
will carry. None of those are true here, and "we might need it later" is how
an architecture diagram gets to twelve boxes.

**The database password is generated, never a variable.** A variable ends up in
a tfvars file, and a tfvars file ends up in git. It goes straight to Secrets
Manager, and the instance role can read exactly that one secret.

**Port 80 redirects rather than serving.** Serve both and somebody eventually
links to the `http://` address.

## The cost decisions

These are the questions an interviewer actually follows up on, so each one is
a variable with the trade-off written next to it:

| Choice | Dev | Why |
|---|---|---|
| `single_nat_gateway` | `true` | One NAT is ~$33/month; one per AZ triples that. The catch: losing that AZ takes outbound connectivity from *every* AZ. |
| `multi_az` (RDS) | `false` | Roughly doubles database cost. It is the difference between a failover in minutes and a restore in hours. |
| `deletion_protection` | `false` | So dev can actually be torn down at the end of the day. |
| `backup_retention_days` | `7` | Still backed up. "It is only dev" holds until somebody has two weeks of test data in it. |
| `enable_waf` | `true` | ~$5/month plus requests. The rate limit alone justifies it. |

The one I would defend hardest is keeping backups on in dev. The validation
block refuses to accept `0`:

```hcl
validation {
  condition     = var.backup_retention_days >= 1
  error_message = "Retention of 0 disables automated backups. If that is genuinely intended, say so somewhere more visible than a tfvars file."
}
```

## The WAF

Three managed rule groups, and they are deliberately not all set the same way:

- **Rate limiting** blocks. 2000 requests per five minutes from one IP. This
  is the rule that earns its keep against credential stuffing.
- **KnownBadInputs** blocks from day one. It matches specific exploit
  signatures like Log4Shell's `${jndi:` rather than inferring intent from
  ordinary traffic, so its false-positive rate is close to zero. Counting a
  known-exploited RCE while you "evaluate" it is not a real position.
- **CommonRuleSet** counts. This one *does* have false positives against
  real applications, and discovering that by blocking production traffic is
  the wrong order. Move it to block once the sampled requests show what it
  would have caught.
- **AnonymousIpList** counts, and stays counting. A large share of ordinary
  users sit behind a corporate VPN. Blocking is a support-ticket generator;
  the metric is genuinely useful for characterising a traffic burst.

Logs redact `authorization` and `cookie`, because a WAF log is read by more
people than the application's own logs are.

## State

S3 with native locking, no DynamoDB table:

```hcl
backend "s3" {
  key          = "dev/terraform.tfstate"
  encrypt      = true
  use_lockfile = true
}
```

`use_lockfile` uses S3 conditional writes and replaced the DynamoDB table that
every older guide still tells you to create. One less resource, one less thing
to pay for, one less thing to forget.

The bucket is supplied at init rather than hardcoded, so the same code serves
every environment:

```bash
tofu -chdir=envs/dev init \
  -backend-config="bucket=my-org-tfstate" \
  -backend-config="region=us-east-1"
```

## The checkov skips

Nine, and each carries its reason on the resource. Two are worth reading
because they are *not* "I could not be bothered":

**`CKV2_AWS_76` and `CKV2_AWS_31`**: the WAF genuinely has both required rule
groups and a logging configuration. Checkov's graph checks cannot traverse a
`count`-gated resource. I confirmed that rather than assuming it: deleting
`count = var.enable_waf ? 1 : 0` takes the run from 190 passed / 1 failed to
191 passed / 0 failed, with no other change.

**`CKV2_AWS_57`**: automatic secret rotation needs a rotation Lambda with
network access to the database, which is more than this module covers. IAM
database authentication is enabled as the path that avoids a long-lived
password entirely; the generated one is the fallback.

The rest are the standard KMS key-policy root grant, which cannot be narrowed
without orphaning the key.

## What I fixed rather than skipped

Checkov's first run found seven failures. Six were real and got fixed:

- The VPC's default security group allows everything between its members.
  Nothing uses it, but an instance launched without an explicit group lands
  there, so it is declared with no rules, which empties it, since it cannot
  be deleted.
- Flow log retention was 90 days. Flow logs get asked "was this happening
  before the incident too", usually months later. A year, with a validation
  block so it cannot be lowered quietly.
- RDS had no query logging. `log_min_duration_statement = 1000`, slow queries
  only, because logging every statement on a busy database costs more I/O than
  the queries do.
- `rds.force_ssl = 1`. Postgres accepts plaintext otherwise, and "we assumed
  the VPC was private" is how database traffic ends up readable to everything
  else in it.
- IAM database authentication enabled.
- The database KMS key had the implicit account-wide policy. Now explicit and
  scoped to the RDS service in this account.

## Never applied

There is no AWS account behind this. Every claim here is `tofu validate` plus
`checkov`, and the plan job in CI skips unless `vars.AWS_REGION` is set. I
would rather say that than imply a bill I have not paid.

## Layout

```
modules/network/    VPC, subnets, NAT, routing, flow logs
modules/web/        ALB, ASG, launch template, WAF, IAM
modules/database/   RDS, subnet group, parameter group, Secrets Manager
envs/dev/           the three modules wired together
```

## Licence

MIT.
