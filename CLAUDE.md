# aws-multi-az-failover

A Python web app (Taskboard) deployed across two AWS Availability Zones with event-driven
automated failover, CodeDeploy deployments, a GitHub Actions CI/CD pipeline and Amazon
Bedrock for AI incident reports and CI failure analysis. Built with Terraform.
A personal learning project.

Services covered: EC2/ASG, NLB, DynamoDB, CodeDeploy, CloudWatch, EventBridge,
Step Functions, Lambda, SNS, KMS, SSM, S3, IAM (incl. GitHub OIDC), Bedrock.

## How to work with me (read first)

- I am a Cloud/DevOps engineer learning these services hands-on. Explain what you build and
  WHY, in simple Tenglish (Telugu-English). Keep all code, comments and docs in English.
- We build **one phase at a time**. Do not create files for future phases.
- **End-to-end run mode (current):** Claude builds AND deploys phases 2 to 8, then I learn
  from the working system. For every phase, in order: code -> checks (fmt/validate/ruff/
  pytest/`bash -n`) -> commit (`feat(phase-N): ...`) -> deploy -> run that phase's tests
  -> record the result. Do not start the next phase until the current phase's
  "done when" criteria pass.
- **Claude MAY run**: `terraform init/plan/apply` for `bootstrap/` and `envs/dev/`, the
  deploy scripts, `gh` CLI, and AWS CLI against resources of this project. Show the plan
  summary (add/change/destroy) before every apply, and stop if a plan wants to destroy or
  replace anything unexpected.
- **Claude must NEVER**:
  - destroy or modify `bootstrap/` after Phase 0 is deployed;
  - delete S3 buckets or Terraform state files;
  - run `terraform destroy` without asking me first;
  - touch any AWS resource that was not created by this project.
- **Stop and wait for me only when I must act by hand**: SNS email confirmation, Bedrock
  model access, GitHub Environment reviewer approval, or a real blocker. Tell me exactly
  what to click.
- **Learning log**: keep `docs/deploy-log.md` updated: for every command run, the command,
  why, what the output meant, and any error + how it was fixed.
- When I paste an error, explain the likely cause first, then how to confirm it, then the fix.
- Never hardcode or commit secrets, AWS keys, account IDs or my email.
  `terraform.tfvars` is gitignored; commit `terraform.tfvars.example` instead.
- At the end of each phase give me: files created, how to test (exact commands),
  expected output, how to destroy, and 3-4 lines for `docs/learnings.md`.
- Use Conventional Commits (`feat:`, `fix:`, `docs:`). Do not push unless I ask.

## Goal

Two single-instance Auto Scaling Groups sit behind one Network Load Balancer:
ASG-a in `us-east-1a` (active) and ASG-b in `us-east-1b` (standby, desired = 0).
Both run the Taskboard app; data lives in DynamoDB, so nothing is lost when the AZ changes.
When the active AZ has no healthy target, the system fails over to the standby automatically
and emails me an AI-written incident report. A manual failback moves traffic back.

## Architecture flow

```
Client -> NLB (TCP 80, HTTP health check /healthz) -> Target group
       -> ASG-a (active) | ASG-b (standby, 0)
       -> nginx -> Taskboard (FastAPI, systemd) -> DynamoDB (via VPC gateway endpoint)

Deploy:
GitHub Actions -> build app zip -> S3 artifacts bucket -> CodeDeploy (in-place)
  -> both ASGs; a new instance launched by an ASG gets the last good revision automatically

Failover (automatic):
CloudWatch alarm (HealthyHostCount < 1) -> EventBridge rule (state = ALARM)
  -> Step Functions "failover"
       1. Precheck Lambda (split-brain + deployment guard)
       2. Choice: proceed? else notify "skipped" and end
       3. scale_asg Lambda: standby ASG desired = 1
       4. Wait 30s -> check_targets Lambda -> healthy in standby AZ?
          (loop, max ~15 min, else fail)
       5. scale_asg Lambda: active ASG desired = 0
       6. Bedrock: write incident report (non-blocking, see decision 16)
       7. SNS publish "failover succeeded" + report (direct SDK integration, no Lambda)
     Catch on any error -> Bedrock failure analysis (non-blocking)
       -> SNS publish "failover FAILED" + analysis -> Fail state

Failback (manual, scripts/start_failback.sh):
Step Functions "failback": same pattern, reverse direction.
```

## Tech stack and conventions

- Terraform >= 1.11, AWS provider pinned to a major version. Region `us-east-1`.
- Remote state: S3 backend with native locking (`use_lockfile = true`), no DynamoDB lock table.
- Locally the provider uses `var.aws_profile`; in GitHub Actions it uses OIDC credentials.
  No keys in code.
- `default_tags`: `Project = aws-multi-az-failover`, `ManagedBy = terraform`, `Owner = var.owner`.
- Name prefix: `var.name_prefix` (default `mazf`).
- App: Python 3.11, FastAPI + uvicorn, boto3. Frontend: plain HTML/CSS/vanilla JS, no build step.
- Lambdas: Python 3.12, boto3 only, zipped with Terraform `archive_file`.
  Each Lambda does ONE thing; all decision logic lives in Step Functions.
- State machines: Standard type, ASL in `statemachines/*.asl.json`, rendered with
  `templatefile()`. Logging level ERROR to a CloudWatch log group.
- All log groups created explicitly with 7-day retention.
- IAM: least privilege, scoped to specific ARNs wherever the API allows.
- Python quality: `ruff` for lint/format, `pytest` for tests.

## Key design decisions (do not change without asking)

### Network and compute
1. **No NAT Gateway** (cost). Public subnets, instances get public IPs, but the instance
   security group allows port 80 **only from the NLB security group**. No SSH; access via
   SSM Session Manager (`AmazonSSMManagedInstanceCore`). IMDSv2 required.
2. **NLB has a security group** (must be set at creation). Ingress port 80 from
   `var.allowed_cidr` (my IP). Cross-zone load balancing enabled. Target group health check
   is **HTTP `GET /healthz`** on port 80, interval 10s.
3. **AMI**: Amazon Linux 2023 via SSM parameter
   `/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64`. `t3.micro`.
4. **user_data is minimal**: install `python3.11`, `nginx`, the CodeDeploy agent (official
   install script from the regional `aws-codedeploy-us-east-1` bucket), enable services.
   **No app code in user_data**; the app arrives only through CodeDeploy.
5. **Both ASGs attach to the same target group.** Each ASG uses exactly one subnet.
   ASG-a: min 0, max 1, desired 1. ASG-b: min 0, max 1, desired 0.
6. **`health_check_type = "EC2"`** on ASGs, so the ASG does NOT self-heal when the app is
   down. Otherwise the ASG would replace the instance and the failover would never trigger.
7. **`lifecycle { ignore_changes = [desired_capacity] }`** on both ASGs, because Lambda
   changes desired capacity at runtime and Terraform must not revert it.

### App (Taskboard)
8. **Taskboard** = simple Kanban board: columns To do / In progress / Done; task has
   `id` (uuid), `title`, `priority` (low/med/high), `status`, `created_at`, `updated_at`.
   Header badge "Served from <AZ>" (1a = green, 1b = purple); footer shows instance ID and
   table name. Clean, modern, light/dark friendly. If the API is unreachable, show a
   "Connection lost, retrying" banner and keep retrying every 2s.
   - `GET/POST /api/tasks`, `PATCH/DELETE /api/tasks/{id}`: DynamoDB
   - `GET /api/meta`: AZ, instance ID, instance type, app version (read from IMDSv2 once at
     startup; version from the deployed bundle)
   - `GET /healthz`: 200 only if the app is up AND a cheap DynamoDB call works; else 503
   - `GET /status`: live failover status page (polls `/api/meta` every 2s, timeline of the
     last ~60 checks in green/purple/red, availability %, measured "Last downtime (RTO)")
   - All API responses send `Cache-Control: no-store`.
9. **DynamoDB**: on-demand table `<prefix>-tasks`, partition key `id`. Reached through a
   **DynamoDB VPC gateway endpoint** (free). Instance role can access only this table.
10. **App runtime**: systemd service `taskboard` (uvicorn on 127.0.0.1:8000), nginx on port 80
    reverse-proxies to it. App installed under `/opt/taskboard`.
11. **Dependencies are vendored at build time** (`pip install --target vendor/ --platform
    manylinux2014_x86_64 --python-version 3.11 --only-binary=:all:`), so instances never
    run `pip install` during deploy.

### Deployment (CodeDeploy)
12. **CodeDeploy, in-place, EC2/On-premises platform**:
    - One application, **one deployment group containing both ASGs** (so a deployment never
      targets zero instances), config `CodeDeployDefault.AllAtOnce`, automatic rollback on
      `DEPLOYMENT_FAILURE`. **No load balancer info** in the deployment group: deregistering
      the only target would drop HealthyHostCount to 0 and could trigger a failover.
    - Bundle = `app/` zipped with `appspec.yml`, uploaded to the artifacts bucket as
      `releases/<git-sha>.zip`.
    - Hooks (`app/codedeploy/`): `ApplicationStop`, `BeforeInstall`, `AfterInstall`,
      `ApplicationStart`, `ValidateService` (curl `/healthz` with retries, max ~60s).
    - **All hook scripts must be idempotent and safe on a fresh instance** (directories may
      not exist yet, service may not be installed yet). A failed hook on a newly launched
      instance makes CodeDeploy fail the launch lifecycle hook and the ASG terminates the
      instance, causing a launch/terminate loop. Hook timeout 300s.
    - ASG instance refresh is only for launch template / AMI changes, not app releases.

### Monitoring and failover
13. **Outage simulation** = stop the `taskboard` service on the active instance via SSM
    Run Command (`AWS-RunShellScript`), not stopping or terminating the instance.
14. **Alarm**: `AWS/NetworkELB` `HealthyHostCount` for the target group, `< 1`,
    period 60s, 2 evaluation periods, `treat_missing_data = breaching`.
    Alarm also notifies SNS directly.
    **EventBridge**: rule on `aws.cloudwatch` / `CloudWatch Alarm State Change`,
    filtered to our alarm ARN and `state.value = ALARM`, target = failover state machine.
15. **Precheck Lambda** gets the state machine ARN from the execution context
    (`$$.StateMachine.Id`) in its payload, NOT from an env var (avoids a circular
    dependency). It skips (with a "skipped" email and the reason) if:
    - the standby ASG desired > 0 already, or
    - another execution of this state machine is RUNNING, or
    - a CodeDeploy deployment for our deployment group is in progress (a bad release would
      also be deployed to the standby, so failover would not help).
    **SNS**: topic encrypted with a customer-managed KMS key whose policy allows
    `cloudwatch.amazonaws.com` and the Step Functions role (the AWS-managed `aws/sns` key
    does not work with CloudWatch alarms). Email subscription from `var.alert_email`.

### Bedrock
16. **Bedrock incident reporter** (state machines):
    - Step Functions calls Bedrock directly with the optimized integration
      (`arn:aws:states:::bedrock:invokeModel`), no Lambda.
    - Success path: after scale-down, send the execution facts (alarm time, timestamps of
      each step from `$$.State.EnteredTime`, source/target AZ and ASG, measured duration)
      and ask for a short incident report: summary, timeline, suggested next steps.
    - Failure path: inside the Catch, send the `Error` and `Cause` plus the facts and ask
      for likely cause and what to check.
    - **AI is never on the recovery path.** Bedrock states have their own Catch and a short
      timeout; on any Bedrock error, fall back to the plain SNS message.
    - Same reporter is used by the failback state machine.
17. **Bedrock CI failure analyzer** (GitHub Actions):
    - Every CI step writes its output to `logs/<step>.log` (via `tee`) and uploads them as an
      artifact. A final job `ai-analyze` runs with `if: failure()` and
      `continue-on-error: true`: takes the last ~200 lines of the failed logs, masks
      12-digit numbers (account IDs) and anything that looks like a key, calls
      `aws bedrock-runtime converse`, and posts "What failed / Likely cause / How to fix"
      as a PR comment (job summary for non-PR runs).
    - It never changes the pipeline result.
18. **Bedrock common rules**: model is `var.bedrock_model_id` / repo variable
    `BEDROCK_MODEL_ID` (a small, cheap model; newer models in us-east-1 need an inference
    profile ID). Low `max_tokens` (~600). Prompts in `prompts/*.txt` tell the model to use
    only the given facts and not to invent details. `bedrock:InvokeModel` is scoped to that
    model / inference profile ARN only. Never send secrets or credentials to the model.

### CI/CD (GitHub Actions)
19. **Auth via GitHub OIDC, no AWS keys in GitHub.** Two IAM roles (created in `bootstrap/`):
    - `<prefix>-gha-plan`: read-only (`ReadOnlyAccess` + state bucket read/lock), trusted for
      pull requests from this repo only.
    - `<prefix>-gha-deploy`: permissions to apply this project, trusted **only for the
      GitHub Environment `dev`**, which has me as required reviewer.
20. **Workflows** (`.github/workflows/`):
    - `ci.yml` (pull_request): `terraform fmt -check`, `validate`, `tflint`, `checkov`;
      `ruff` + `pytest` for app and Lambdas; build the app bundle (no upload);
      `terraform plan` (plan role) posted as a PR comment.
    - `deploy.yml` (`workflow_dispatch`, input: `infra` | `app` | `both`; environment `dev`
      approval): terraform apply and/or build app -> upload to S3 -> create CodeDeploy
      deployment -> wait for result.
    - `destroy.yml` (`workflow_dispatch`, environment `dev` approval): `terraform destroy`
      for `envs/dev` only.
    - Deploys are manual on purpose: the stack is destroyed after every session.

## Repo structure

```
aws-multi-az-failover/
├── CLAUDE.md
├── README.md
├── .gitignore
├── .github/workflows/          # Phase 3: ci.yml, deploy.yml, destroy.yml (ai-analyze in Phase 7)
├── bootstrap/                  # Phase 0: state bucket, artifacts bucket, budget, GitHub OIDC
├── envs/dev/                   # backend.tf, providers.tf, main.tf, variables.tf,
│                               # outputs.tf, terraform.tfvars.example
├── modules/
│   ├── network/                # Phase 1: VPC, subnets, IGW, SGs, DynamoDB gateway endpoint
│   ├── nlb/                    # Phase 1
│   ├── compute/                # Phase 1: launch template, ASGs, instance role, user_data.sh
│   ├── data/                   # Phase 1: DynamoDB table
│   ├── deploy/                 # Phase 1: CodeDeploy app, deployment group, service role
│   ├── monitoring/             # Phase 4
│   ├── failover/               # Phase 5 + 6
│   └── scheduler/              # Phase 8 (optional)
├── app/                        # Phase 2: Taskboard
│   ├── taskboard/              # main.py, db.py, meta.py, static/index.html, static/status.html
│   ├── tests/                  # pytest (DynamoDB mocked with moto)
│   ├── requirements.txt
│   ├── appspec.yml
│   ├── codedeploy/             # hook scripts
│   └── config/                 # taskboard.service, nginx.conf
├── lambda/
│   ├── precheck/handler.py
│   ├── scale_asg/handler.py
│   └── check_targets/handler.py
├── statemachines/
│   ├── failover.asl.json
│   └── failback.asl.json
├── prompts/                    # Phase 7: incident_report.txt, failure_analysis.txt,
│                               # ci_failure_analysis.txt
├── scripts/                    # status.sh, build_app.sh, deploy_app.sh,
│                               # simulate_outage.sh, start_failback.sh
└── docs/                       # architecture.md, runbook.md, learnings.md
```

## Phases and done criteria

| Phase | Build | Done when |
|---|---|---|
| 0 | `bootstrap/`: state bucket (versioning, encryption, block public access), artifacts bucket (30-day expiry on `releases/`), monthly AWS Budget ($10, email alert), GitHub OIDC provider + plan/deploy roles | Buckets exist, budget visible, roles visible in IAM |
| 1 | network (+ DynamoDB endpoint), nlb, compute, data, deploy modules; `envs/dev` wiring; `scripts/status.sh` | ASG-a has 1 InService instance, ASG-b has 0; CodeDeploy agent running (check via Session Manager); target unhealthy is expected (no app yet) |
| 2 | Taskboard app + tests, appspec + hooks, `scripts/build_app.sh`, `scripts/deploy_app.sh` | `pytest` passes; deployment Succeeded; board works at `http://<nlb-dns>`; tasks persist in DynamoDB; `/status` works |
| 3 | CI/CD: `ci.yml`, `deploy.yml`, `destroy.yml`, GitHub Environment `dev` | PR shows green checks + plan comment; app change deployed via `deploy.yml` after approval |
| 4 | monitoring: SNS + KMS + email sub, CloudWatch alarm, `scripts/simulate_outage.sh` | Stop app -> alarm ALARM -> email received |
| 5 | failover: 3 Lambdas, failover state machine, EventBridge rule, IAM | Simulate outage -> automatic failover -> board served from us-east-1b with the same tasks -> success email |
| 6 | failback state machine, `scripts/start_failback.sh` | Run script -> back on us-east-1a, same tasks -> email |
| 7 | Bedrock: incident reporter in both state machines + CI `ai-analyze` job, `prompts/`, IAM | AI report in failover email; AI comment on a failing PR; wrong model ID never breaks failover or CI |
| 8 (optional) | scheduler: EventBridge Scheduler scales ASGs to 0 at night, back up in the morning | Schedules visible and fire correctly |

## Test plan (goes into docs/runbook.md)

Never test by terminating the active instance: ASG-a would relaunch in the same AZ while
the failover also starts, giving a confusing race. Outage = stop the `taskboard` service.

1. **Failover (happy path):** add 3-4 tasks; open the board and `/status` ->
   `scripts/simulate_outage.sh` -> alarm email -> Step Functions run succeeds -> board shows
   us-east-1b **with the same tasks** -> success email. Record the measured RTO.
2. **Failback:** `scripts/start_failback.sh` -> back on us-east-1a, same tasks -> email.
3. **Split-brain guard:** while on AZ-b, start the failover state machine manually ->
   precheck skips, "skipped" email, no scaling.
4. **Failure path:** start the state machine manually with a wrong ASG name in the input ->
   Catch -> "FAILED" email (with AI analysis after Phase 7).
5. **Deploy:** change the app (e.g. header text) -> PR -> CI green -> `deploy.yml` (app)
   -> approve -> new version visible.
6. **Bad deploy rollback:** make `ValidateService` fail on purpose -> deployment fails ->
   automatic rollback -> previous version still served.
7. **Fresh-instance deploy:** run a failover -> the new AZ-b instance gets the last good
   revision through the CodeDeploy launch hook, with no launch/terminate loop.
8. **Bedrock (Phase 7):** check the AI report timeline against the execution history;
   open a PR with a broken `.tf` file -> AI comment explains the error; set a wrong model
   ID -> failover and CI still behave exactly the same.
9. **Instance failure (optional):** suspend `Launch`, `HealthCheck`, `ReplaceUnhealthy` on
   ASG-a, stop (not terminate) the AZ-a instance -> failover. Resume processes afterwards.
10. **Cleanup:** failback, then `terraform plan -destroy` (confirm bootstrap is not
    included), then `terraform destroy` in `envs/dev` (or `destroy.yml`).

`scripts/simulate_outage.sh` must find the active instance from ASG-a and use SSM Run Command
(`AWS-RunShellScript`). `scripts/status.sh` shows ASG desired/in-service per AZ, NLB target
health, alarm state, latest state machine execution and latest CodeDeploy deployment.

## Cost guardrails

- No NAT Gateway, no extra Elastic IPs, `t3.micro` only.
- The NLB and KMS key cost money even when idle: I destroy `envs/dev` after every session.
  `bootstrap/` stays (S3 + IAM, near zero cost).
- DynamoDB on-demand, gateway endpoint (free), CodeDeploy on EC2 (free).
- Bedrock is pay per token: small model, low `max_tokens`, one call per execution / failed run.
- GitHub Actions: keep workflows lean (cache providers/pip) to stay within free minutes.
- Before any apply, tell me which resources cost money per hour/month.
