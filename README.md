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
- [Evidence](#evidence)
- [Repository layout](#repository-layout)
- [Design decisions](#design-decisions)
- [Teardown](#teardown)

---

## What it does

| Layer | Tool | What it gives you |
|-------|------|-------------------|
| Metrics | Prometheus | Scrapes 6 targets every 15s, evaluates 4 alert rules |
| Dashboards | Grafana | Latency, requests/sec, error rate, host health |
| Notification | Alertmanager | Routes firing alerts to Discord |
| Logs | CloudWatch Logs | Containers via the Docker `awslogs` driver, Jenkins via the CloudWatch agent |
| Audit | CloudTrail | Multi-region trail into an encrypted, versioned S3 bucket with lifecycle rules |
| Threat detection | GuardDuty | Continuous analysis of CloudTrail, VPC flow and DNS logs |

### Scrape targets

Six targets across four jobs.

| Job | Target | Exposes |
|-----|--------|---------|
| `prometheus` | itself | scrape durations, TSDB size, rule failures |
| `node` | all 3 hosts | CPU, memory, disk, load, network |
| `weather-app` | app server `/metrics` | request counts, durations, status codes |
| `jenkins` | Jenkins `/prometheus/` | build queue, executors, job durations |

### Alert rules

Four rules in two groups. The one the project requires is **HighErrorRate** —
5xx responses above 5% of traffic, sustained for 2 minutes.

| Group | Rules |
|-------|-------|
| weather-app | HighErrorRate, HighLatency, AppDown |
| hosts | HostDown |

`AppDown` covers the `weather-app` job and `HostDown` covers the `node` job, so
their scopes cannot overlap and one incident produces one notification.

---

## Architecture

One new EC2 instance joins the existing VPC and scrapes the two hosts that were
already there.

![Architecture diagram](monitoring-lab-architecture.png)

Solid lines are metrics being **pulled**; dashed lines are logs being **pushed**.
The monitoring server scrapes the app server and the Jenkins server over the VPC
(9100 for node_exporter, 80 for the app, 8080 for Jenkins), and Alertmanager
pushes notifications out to Discord. Independently, all three hosts push logs to
CloudWatch Logs, CloudTrail delivers its own logs to an S3 bucket, and GuardDuty
continuously analyses both.

Nothing is pushed to Prometheus, which is why the security groups must let the
monitoring host reach those exporter ports inside the VPC. It is also why a
target showing DOWN is more often a network rule than a broken exporter.

Prometheus and Grafana publish their own ports, restricted by security group to
the operator's IP. Prometheus has no authentication of its own, so access
control is at the network layer; Grafana keeps its own login.

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
cp terraform.tfvars.example terraform.tfvars
terraform init
terraform apply
```

Creates: the monitoring EC2 instance and its security group, an IAM instance
profile for CloudWatch, the CloudTrail bucket and trail, the GuardDuty detector,
and the CloudWatch log groups with 14-day retention.

The security group allows SSH, 3000 and 9090 from `local.admin_cidr`, which is
resolved from `checkip.amazonaws.com` at plan time. **Change networks and you
lock yourself out until you re-apply.**

**GuardDuty allows one detector per account per region.** If the account already
has one, import it before applying or `terraform apply` will fail:

```bash
aws guardduty list-detectors --profile sandbox-user --region eu-west-1
terraform import aws_guardduty_detector.main <detector-id>
```

### 2. Secrets

The Discord webhook URL contains a token that grants posting rights to the
channel, so it is treated as a credential — kept out of git, and out of
Ansible's run output.

```bash
cd ../ansible
mkdir -p group_vars/all
echo 'alertmanager_discord_webhook: "https://discord.com/api/webhooks/..."' \
  > group_vars/all/secrets.yml
```

`group_vars` files are named after **inventory groups**, not merged by filename.
A file called `group_vars/secrets.yml` loads only if a group named `secrets`
exists — otherwise Ansible ignores it silently and the `CHANGE-ME` placeholder
reaches the host. Making `all` a directory means every file inside it loads for
every host: `all/main.yml` holds committed defaults, `all/secrets.yml` (which is
gitignored) holds the webhook.

### 3. Configuration

```bash
ansible-playbook site.yml
```

Two plays: node_exporter on all hosts, then the monitoring stack on the new
host. Hosts come from the EC2 dynamic inventory and are grouped by their `Role`
tag, so no IP is ever written down.

The run ends by reporting how many scrape targets are UP — the single most
useful check in the whole playbook.

### 4. Verify

```bash
IP=$(cd ../terraform && terraform output -raw monitoring_public_ip)

curl -s "http://$IP:9090/-/ready"                                    # Prometheus OK
curl -s "http://$IP:9090/api/v1/query?query=sum(up)" | grep -o '"value".*'   # 6
curl -s -o /dev/null -w '%{http_code}\n' "http://$IP:3000/api/health"        # 200

aws logs tail /weather-app/web --since 10m --profile sandbox-user --region eu-west-1
aws logs tail /jenkins/system  --since 10m --profile sandbox-user --region eu-west-1
```

---

## Access

```bash
terraform output monitoring_url    # Grafana  :3000
terraform output prometheus_url    # Prometheus :9090
```

| URL | What | Auth |
|-----|------|------|
| `http://<ip>:3000/` | Grafana dashboards | Grafana login |
| `http://<ip>:9090/targets` | Scrape health — first place to look | none; security group |
| `http://<ip>:9090/alerts` | Alert rules and their state | none; security group |

Both ports are restricted to the operator's IP.

---

## Evidence

Screenshots proving the monitoring path works end to end, walked in the order
data actually flows: metrics get collected, dashboards render them, alert rules
evaluate them and notify, and everything is separately logged and audited.

### 1. Metrics are being collected

![Prometheus targets](screenshots/prom-targets.png)

All six targets UP across four jobs. This is the single best proof that the
scrape path works end to end — security groups, exporters, and the app's own
`/metrics` endpoint all have to be correct for this page to look like this.

![Prometheus query graph](screenshots/prom-graph.png)

A PromQL query graphing request rate by HTTP status. The visible 200, 400 and
404 series confirm that application metrics aren't just scraped but queryable.

### 2. Dashboards visualize them

![Grafana dashboard overview](screenshots/grafana-dash-1.png)

The Application row: error rate, requests per second, requests by status, and
latency percentiles — the three signals the project requires, plus a count of
targets up. Loaded from JSON in this repo rather than saved in the Grafana UI,
so it survives a container rebuild.

![Host health panels](screenshots/grafana-dash-2.png)

The Hosts row: CPU, memory and root disk across all three machines from
node_exporter — infrastructure health alongside application health.

![Latency percentiles](screenshots/grafana-latency.png)

p50/p95/p99 latency. An average would hide the tail: ninety-nine fast requests
and one very slow one average out to something that looks fine while a real user
waited ten seconds. The alert fires on p95 above one second.

![Grafana data source](screenshots/grafana-data-sources.png)

Grafana's Prometheus data source, provisioned rather than clicked in.

### 3. Alert rules evaluate them

![Alert rules](screenshots/prom-rules.png)

All four rules loaded, including the one the project requires, `HighErrorRate`
(5xx above 5% of traffic, sustained 2 minutes).

![Alert firing](screenshots/alert-firing.png)

A rule firing under an induced outage. `HighErrorRate` uses the same evaluation
mechanism with a different expression — a rule reaching FIRING here proves the
whole path, not just that the rules parse.

### 4. ...and notify Discord

![Discord alert notification](screenshots/discord-notification.png)

The alert arriving in the `#alerts` Discord channel with its severity and
instance labels intact, and the matching RESOLVED notification once the service
recovered. This closes the chain: rule evaluated in Prometheus, grouped and
routed by Alertmanager, delivered to a human, and cleared automatically when the
condition ended.

### 5. Logs

![CloudWatch log groups](screenshots/cloudwatch-log-groups.png)

Log groups with an explicit 14-day retention policy declared in Terraform — not
auto-created by the Docker driver, which would keep (and bill for) the data
forever.

![CloudWatch application logs](screenshots/cloudwatch-app-logs.png)

Real application request logs arriving in `/weather-app/web`.

### 6. Audit and threat detection

![CloudTrail trail configuration](screenshots/cloudtrail-trail.png)

The multi-region trail, with log file validation enabled.

![S3 bucket lifecycle policy](screenshots/cloudtrail-lifecycle-rule.png)

The trail's destination bucket: encrypted, versioned, public access blocked, and
a lifecycle policy moving objects to Infrequent Access at 30 days, Glacier IR at
90, and expiring them at 365.

![GuardDuty sample findings](screenshots/guardduty-findings.png)

GuardDuty enabled, with sample findings generated deliberately via
`aws guardduty create-sample-findings`. These are labelled `[SAMPLE]` — the
account was not actually attacked. They exist to exercise the detection and
display path end to end without waiting for a real incident.

---

## Repository layout

```
terraform/    monitoring host, IAM, CloudTrail + S3, GuardDuty, CloudWatch groups
ansible/      roles: docker, node_exporter, monitoring
monitoring/   docker-compose.yml, prometheus config and rules, Alertmanager
              config, Grafana provisioning
screenshots/  evidence
monitoring-lab-architecture.png   architecture diagram (see Architecture)
```

Everything under `monitoring/` is the source of truth; Ansible copies it to
`/opt/monitoring` on the host. Only two files are templated, because only two
depend on runtime facts:

- `prometheus/prometheus.yml.j2` — needs every host's private IP, from inventory
- `ansible/roles/monitoring/templates/env.j2` — image tags, credentials, public IP

Everything else is plain YAML, so the file you read in the repo is byte-for-byte
the file running on the host.

---

## Design decisions

**Scope kept to what the requirements call for.** An earlier version added an
nginx reverse proxy with basic auth, cAdvisor, nginx-exporter, nine alert rules
and twenty-one dashboard panels. That was more machinery than a single-file
Flask app needs, and complexity that cannot be explained is a liability rather
than an asset. It was cut back to the stated requirements.

**Network-layer access control, not basic auth.** Prometheus has no
authentication of its own, so the security group restricts port 9090 to the
operator's IP. The previous basic-auth proxy sent credentials in the clear over
plain HTTP to anyone who could already reach the port — a weak control layered
on a strong one. In production both ports would terminate TLS.

**`/metrics` restricted to the VPC.** Metrics leak endpoint names, traffic
volumes, error rates and version numbers, which is reconnaissance material. The
app's nginx allows the VPC CIDR so Prometheus can scrape it and denies the rest.
Side effect worth knowing: curling it *from the app server itself* returns 403,
because Docker's NAT rewrites host-local traffic to a bridge address outside the
allowed range. That is the rule working — test from the monitoring host.

**IAM instance profile, not access keys.** Both hosts assume a role for
CloudWatch access. No long-lived credentials exist anywhere in this repo or on
any instance.

**Compose is static; only `.env` is generated.** Docker Compose substitutes
`${VAR}` from a `.env` file beside it, so `docker-compose.yml` is plain YAML and
every deployment-specific value lives in one seven-line file. Templating the
compose file itself meant the version in the repo was never the version running.

**Directory bind mounts, not single files.** A single-file bind mount binds that
file's *inode*. Ansible writes a temp file and renames it into place, creating a
new inode — so the container keeps serving the old content and a reload re-reads
a file that no longer exists. Mounting the directory makes Docker resolve the
path on each open.

**File modes account for container UIDs.** Containers share the host's numeric
UID namespace but not its user names. Alertmanager runs as UID 65534, so a
config file at mode 0640 owned by `ec2-user` is unreadable to it and the
container crash-loops. Config files that containers read are mode 0644.

**Dashboards provisioned from JSON.** Saving a dashboard in the Grafana UI
creates drift that disappears the next time the container is recreated. The JSON
in this repo is authoritative.

**Targets generated from inventory.** Scrape addresses are rendered into
`prometheus.yml` from the EC2 dynamic inventory when Ansible runs, so no IP is
hand-written. Rebuild the infrastructure, run the playbook, and the addresses
are correct again.

**AMI pinned rather than resolved.** A `data "aws_ami"` lookup with
`most_recent = true` re-resolves on every plan, so the day AWS publishes a new
image Terraform wants to replace every instance. Pinning means a plan reflects
intentional changes.

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