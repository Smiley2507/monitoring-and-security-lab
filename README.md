# Monitoring & Security Lab

Observability and threat detection for a containerised Flask weather app running
on AWS: Prometheus, Grafana, Alertmanager, CloudWatch Logs, CloudTrail and
GuardDuty, all provisioned with Terraform and configured with Ansible.

The app itself is built and deployed by
[jenkins-cicd-lab](https://github.com/Smiley2507/jenkins-cicd-lab). That project
answers *"can we ship it?"* — this one answers *"is it healthy, and would we know
if it wasn't?"*

---

## Contents

- [What it does](#what-it-does)
- [Architecture](#architecture)
- [Prerequisites](#prerequisites)
- [Deploy](#deploy)
- [Access](#access)
- [Evidence](#evidence) — screenshots proving each capability
- [Repository layout](#repository-layout)
- [Design decisions](#design-decisions)
- [Teardown](#teardown)

---

## What it does

| Layer | Tool | What it gives you |
|-------|------|-------------------|
| Metrics | Prometheus | Scrapes 9 targets every 15s, evaluates 9 alert rules |
| Dashboards | Grafana | Latency, requests/sec, error rate, host and container health |
| Notification | Alertmanager | Routes firing alerts to Discord |
| Logs | CloudWatch Logs | Containers via the Docker `awslogs` driver, Jenkins via the CloudWatch agent |
| Audit | CloudTrail | Multi-region trail into an encrypted, versioned S3 bucket with lifecycle rules |
| Threat detection | GuardDuty | Continuous analysis of CloudTrail, VPC flow and DNS logs |

### Scrape targets

| Job | Target | Exposes |
|-----|--------|---------|
| `prometheus` | itself | scrape durations, TSDB size, rule failures |
| `node` | all 3 hosts | CPU, memory, disk, load, network |
| `weather-app` | app server `/metrics` | request counts, durations, status codes |
| `cadvisor` | app + monitoring | per-container CPU and memory |
| `nginx` | app server `:9113` | active connections, requests/sec |
| `jenkins` | Jenkins `/prometheus/` | build queue, executors, job durations |

### Alert rules

Nine rules in three groups. The one the project requires is **HighErrorRate** —
5xx responses above 5% of traffic, sustained for 5 minutes.

| Group | Rules |
|-------|-------|
| weather-app | HighErrorRate, HighLatency, AppDown |
| hosts | TargetDown, HighCpuUsage, HighMemoryUsage, LowDiskSpace, HostRebooted |
| containers | ContainerRestarting |

---

## Architecture

One new EC2 instance joins the existing VPC and scrapes the two hosts that were
already there.

![Architecture diagram](monitoring-lab-architecture.png)

Solid lines are metrics being **pulled**; dashed lines are logs being **pushed**.
The monitoring server scrapes the app server and the Jenkins server over the VPC
(9100 / 8080 / 9113), and Alertmanager pushes notifications out to Discord.
Independently, all three hosts push logs to CloudWatch Logs, CloudTrail delivers
its own logs to an S3 bucket, and GuardDuty continuously analyses both. Nothing
is pushed to Prometheus, which is why the security groups must let the
monitoring host reach those three exporter ports inside the VPC.

Grafana and Prometheus are never exposed directly. nginx proxies both, adds HTTP
basic auth in front of Prometheus (which has no authentication of its own), and
only the operator's IP can reach either port.

---

## Prerequisites

- The CI/CD stack deployed and running — this stack discovers its VPC by tag
- Terraform ≥ 1.11, Ansible, AWS CLI with a `sandbox-user` profile in `eu-west-1`
- The CI/CD stack's key pair at `../jenkins-cicd-lab/terraform/cicd-key.pem`
- A Discord webhook URL for alert notifications

---

## Deploy

### 1. Infrastructure

```bash
cd terraform
cp terraform.tfvars.example terraform.tfvars   # set your admin CIDR
terraform init
terraform apply
```

Creates: the monitoring EC2 instance and its security group, an IAM instance
profile for CloudWatch, the CloudTrail bucket and trail, the GuardDuty detector,
and the CloudWatch log groups with 14-day retention.

**GuardDuty allows one detector per account per region.** If the account already
has one, import it before applying or `terraform apply` will fail:

```bash
aws guardduty list-detectors --profile sandbox-user --region eu-west-1
terraform import aws_guardduty_detector.main <detector-id>
```

### 2. Secrets

The Discord webhook URL contains a token that grants the ability to post to the
channel, so it is treated as a credential — kept out of git and out of Ansible's
log output.

```bash
cd ../ansible
echo 'alertmanager_discord_webhook: "https://discord.com/api/webhooks/..."' \
  > group_vars/secrets.yml
```

`group_vars/secrets.yml` is gitignored. Group vars merge alphabetically, so it
overrides the `CHANGE-ME` placeholder in `all.yml`.

### 3. Configuration

```bash
ansible-playbook site.yml
```

Three plays: node_exporter on all hosts, exporters on the app server, and the
monitoring stack on the new host. Hosts come from the EC2 dynamic inventory and
are grouped by their `Role` tag, so no IP is ever written down.

The run ends by reporting how many scrape targets are UP — the single most
useful check in the whole playbook.

### 4. Verify

```bash
# from the monitoring host
curl -u prom:<password> http://localhost:8090/-/ready          # 200
curl -s localhost:8090/api/v1/query?query=sum\(up\) | jq       # 9

# from anywhere with the CLI
aws logs tail /weather-app/web --since 10m --profile sandbox-user --region eu-west-1
aws logs tail /jenkins/system  --since 10m --profile sandbox-user --region eu-west-1
```

---

## Access

```bash
terraform output monitoring_url        # Grafana
terraform output monitoring_public_ip  # Prometheus on :8090
```

| URL | What | Auth |
|-----|------|------|
| `http://<ip>/` | Grafana dashboards | Grafana login |
| `http://<ip>:8090/targets` | Scrape health — first place to look | basic auth |
| `http://<ip>:8090/alerts` | Alert rules and their state | basic auth |

Both ports are restricted to the operator's IP by security group.

---

## Evidence

Screenshots proving the monitoring path works end to end, walked in the order
data actually flows: metrics get collected, dashboards render them, alert
rules evaluate them and notify, and everything is separately logged and
audited.

### 1. Metrics are being collected

![Prometheus targets](screenshots/prom-targets.png)

All nine targets UP across six jobs. This is the single best proof that the
scrape path works end to end — security groups, exporters, and the app's own
`/metrics` endpoint all have to be correct for this page to look like this.

![Prometheus query graph](screenshots/prom-graph.png)

A PromQL query graphing request rate by HTTP status. The visible 200, 400 and
404 series confirm that application metrics aren't just scraped but queryable.

> **Not yet captured:** the app's `/metrics` endpoint in raw Prometheus text
> format. Worth noting for whoever takes it — it returns **403** when curled
> from the app server itself. That's expected: nginx only allows the VPC CIDR,
> and Docker's NAT rewrites host-local traffic to a bridge address. Scrape
> from the monitoring host instead.

### 2. Dashboards visualize them

![Grafana dashboard overview](screenshots/grafana-dash-1.png)

The provisioned dashboard's overview row: throughput, latency and error rate —
the three signals the project requires. Loaded from JSON in this repo rather
than saved in the Grafana UI, so it survives a container rebuild.

![Host and container health panels](screenshots/grafana-dash-2.png)

node_exporter and cAdvisor panels underneath the application row —
infrastructure health alongside application health, on the same dashboard.

![Scrape health panels](screenshots/grafana-dash-3.png)

A per-target scrape health panel, so a broken exporter shows up in Grafana and
not just in Prometheus's own `/targets` page.

![Latency percentiles](screenshots/grafana-latency.png)

p50/p95/p99 latency, broken down by request path — including some paths the
weather app never defined (see [Real-world observation](#7-real-world-observation)
below).

![Grafana data source](screenshots/grafana-data-sources.png)

Grafana's Prometheus data source, provisioned rather than clicked in.

### 3. Alert rules evaluate them

![Alert rules](screenshots/prom-rules.png)

All nine rules loaded, including the one the project requires,
`HighErrorRate` (5xx above 5% of traffic, sustained 5 minutes).

![Prometheus alert groups](screenshots/prom-alerts.png)

The alert groups registered in Prometheus, inactive here because no test load
was running at capture time — Prometheus decides *when* an alert fires.

### 4. ...and notify Discord

![Discord alert notification](screenshots/discord-notification.png)

Alertmanager decides *who and how*: a test alert routed through Alertmanager
and posted to the `#alerts` Discord channel, with severity and instance labels
intact. This confirms the notification path itself — webhook, route and
template — independent of any specific rule firing.

> **Not yet captured:** `HighErrorRate` visibly `FIRING` in the Prometheus
> `/alerts` page under real test load, paired with the Discord message it
> produces. The screenshot above proves the route works; this would prove the
> rule triggers it.

### 5. Logs

![CloudWatch log groups](screenshots/cloudwatch-log-groups.png)

Seven log groups, each with an explicit 14-day retention policy declared in
Terraform — not auto-created by the Docker driver, which would keep (and
bill for) the data forever.

![CloudWatch application logs](screenshots/cloudwatch-app-logs.png)

Real application request logs arriving in `/weather-app/web`.

### 6. Audit and threat detection

![CloudTrail trail configuration](screenshots/cloudtrail-trail.png)

The multi-region trail, with log file validation enabled.

![S3 bucket lifecycle policy](screenshots/cloudtrail-lifecycle-rule.png)

The trail's destination bucket: encrypted, versioned, public access blocked,
and a lifecycle policy moving objects to Infrequent Access at 30 days, Glacier
IR at 90, and expiring them at 365.

![GuardDuty sample findings](screenshots/guardduty-findings.png)

GuardDuty enabled, with sample findings generated deliberately via
`aws guardduty create-sample-findings`. These are labelled `[SAMPLE]` — the
account was not actually attacked. They exist to exercise the detection and
display path end to end without waiting for a real incident.

### 7. Real-world observation

> **Not yet captured:** a Grafana latency panel showing unsolicited internet
> reconnaissance against the public app — automated scanners probing for
> `/.aws/credentials`, `/.bash_history`, `/.env` and similar paths the weather
> app never defined. All returned 404. This traffic isn't staged; it's what
> a publicly reachable host receives within hours, and it's the clearest
> argument for why the security half of this project exists.

---

## Repository layout

```
terraform/    monitoring host, IAM, CloudTrail + S3, GuardDuty, CloudWatch groups
ansible/      roles: docker, node_exporter, app_exporters, monitoring
monitoring/   prometheus.yml, alert rules, Alertmanager config,
              Grafana provisioning, compose file
screenshots/  evidence
monitoring-lab-architecture.png   architecture diagram (see Architecture)
```

Everything under `monitoring/` is the source of truth. Ansible copies it to the
host; nothing is configured by hand.

---

## Design decisions

**Two proxied ports rather than URL sub-paths.** Prometheus and Grafana both
need extra configuration to serve under a prefix, and both fail in confusing
ways when it is slightly wrong. Serving each at the root of its own port avoids
the problem entirely.

**IAM instance profile, not access keys.** Both hosts assume a role for
CloudWatch access. No long-lived credentials exist anywhere in this repo or on
any instance.

**Directory bind mounts, not single files.** A single-file bind mount binds that
file's *inode*. Ansible writes a temp file and renames it into place, creating a
new inode — so the container keeps serving the old content and a reload re-reads
a file that no longer exists. Mounting the directory makes Docker resolve the
path on each open.

**Dashboards provisioned from JSON.** Saving a dashboard in the Grafana UI
creates drift that disappears the next time the container is recreated. The JSON
in this repo is authoritative.

**Targets generated from inventory.** Addresses live in `targets/*.json`,
written by Ansible from the EC2 dynamic inventory and re-read by Prometheus
without a restart. Rebuild the infrastructure and one playbook run points it at
the new IPs.

---

## Teardown

```bash
cd terraform
terraform destroy
```

The CloudTrail bucket has versioning enabled, so empty it first — otherwise the
destroy fails on a non-empty bucket:

```bash
aws s3 rm s3://$(terraform output -raw cloudtrail_bucket) --recursive
```

Verify afterwards that the GuardDuty detector, the trail, the bucket and the
CloudWatch log groups are all gone.