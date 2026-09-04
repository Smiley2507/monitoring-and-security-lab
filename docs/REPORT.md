# Full Observability and Security Solution

Monitoring a containerised Flask application on AWS with Prometheus, Grafana, CloudWatch, CloudTrail and GuardDuty.

---

## 1. Objective

An earlier project delivered a CI/CD pipeline that containerises a Flask weather service and deploys it to EC2. That pipeline establishes whether the application can be built and shipped. It provides no information about the health of the running system, and no mechanism for detecting failure after deployment.

This project addresses that gap by adding metrics collection, dashboards, alerting, centralised logging, and account-level audit and threat detection. The infrastructure is provisioned with Terraform and configured with Ansible, so the entire stack can be rebuilt from an empty account without manual steps.

## 2. Architecture

A single monitoring EC2 instance was added to the existing VPC. It runs Prometheus, Grafana, Alertmanager, cAdvisor and an nginx reverse proxy as one Docker Compose project. The instance locates the VPC through a tag lookup rather than a hardcoded identifier, which keeps the two stacks independent of each other.

Prometheus operates on a pull model. It fetches a plain HTTP metrics page from each target on a fifteen-second schedule; nothing is transmitted to Prometheus by the targets themselves. This has two consequences for the design. The security groups must permit the monitoring host to reach ports 9100, 8080 and 9113 within the VPC, and a target reported as DOWN is more often a network rule than a failed exporter.

Log delivery operates in the opposite direction. Container output is pushed to CloudWatch Logs by Docker's `awslogs` driver. Jenkins runs as a systemd service rather than a container, so its output is collected by the CloudWatch agent instead. Both mechanisms authenticate through an IAM instance profile, and no long-lived access keys exist on any host or in either repository.

## 3. Implementation

| Capability | Component | Detail |
|---|---|---|
| Metrics | Prometheus 3.1.0 | 9 targets across 6 jobs, scraped every 15s. Target addresses are generated from the EC2 dynamic inventory into `file_sd_configs` and re-read without a restart. |
| Dashboards | Grafana 11.5.1 | 21 panels covering requests per second by status, p50/p95/p99 latency, error rate, and host and container health. Provisioned from JSON held in the repository. |
| Alerting | 9 rules, Alertmanager 0.28 | Rules organised in three groups. Alertmanager handles grouping, deduplication and routing to Discord. |
| Logging | CloudWatch Logs | 6 log groups with 14-day retention, declared in Terraform rather than created implicitly by the log driver. |
| Audit | CloudTrail | Multi-region trail with log file validation, delivered to a dedicated S3 bucket. |
| Threat detection | GuardDuty | Detector enabled with a 15-minute finding publishing frequency. |

The principal alerting requirement was to raise an alert when the error rate exceeds 5 percent. The application does not report an error rate directly. It exposes a counter of requests labelled by HTTP status, and Prometheus derives the ratio at query time:

```promql
sum(rate(flask_http_request_total{status=~"5.."}[5m]))
  / sum(rate(flask_http_request_total[5m])) > 0.05
```

A second clause requires a minimum request rate before the alert can fire. Without it, an idle server divides zero by zero and produces NaN. The rule also specifies a two-minute `for:` duration, which distinguishes a single failed request from a fault that has persisted.

## 4. Verification

- All 9 Prometheus targets reported UP, confirming the scrape path end to end across security groups, exporters and the application's `/metrics` endpoint.
- Grafana dashboards populated with live traffic, showing throughput, latency percentiles and error rate.
- All 9 alert rules loaded and evaluating, with `HighErrorRate` visible on the alerts page and its threshold expression confirmed.
- `aws logs tail` confirmed log lines arriving in `/weather-app/web` and `/jenkins/system`.
- CloudTrail digest files were present in the encrypted S3 bucket, and GuardDuty sample findings were generated and displayed.

## 5. Problems encountered

**Container user identifiers.** Both nginx and Alertmanager failed on start or returned HTTP 500 because bind-mounted configuration files were mode 0640 and owned by `ec2-user`. Containers share the host's numeric UID namespace but not its user names. The nginx worker process runs as UID 101 and Alertmanager as UID 65534, so neither matched the file owner or group. Setting mode 0644 resolved both cases.

**Bind mounts resolve to inodes.** A single-file bind mount binds that file's inode rather than its path. Ansible writes to a temporary file and renames it into place, which creates a new inode, so the container continued to serve stale content and a configuration reload re-read a file that no longer existed. Mounting the parent directory instead forces Docker to resolve the path on each open.

**Silently ignored variable files.** Ansible `group_vars` files are named after inventory groups. A file named `secrets.yml` is loaded only when a group named `secrets` exists. No warning is emitted otherwise, and the placeholder value it was intended to override reaches the deployed configuration. Converting `group_vars/all.yml` into a `group_vars/all/` directory resolved the problem.

## 6. Security posture

Prometheus provides no authentication of its own and is therefore never exposed directly. nginx proxies it behind HTTP basic authentication, Grafana retains its own login, and both ports are restricted by security group to the operator's current IP address. The application's `/metrics` endpoint is similarly restricted to the VPC CIDR.

CloudTrail is configured as a multi-region trail with log file validation enabled. It delivers to a bucket that is encrypted, versioned, blocked from public access, and governed by a lifecycle policy: transition to Infrequent Access at 30 days, Glacier Instant Retrieval at 90 days, and expiry at 365 days. The GuardDuty findings included in the evidence are sample findings, generated deliberately to exercise the detection and display path. No genuine compromise occurred.

The latency dashboard, broken down by request path, revealed sustained unsolicited traffic probing for `/.aws/credentials`, `/.bash_history`, `/.env` and comparable files. This is automated internet reconnaissance, which began within hours of the host becoming publicly reachable. All such requests returned HTTP 404. The observation is a practical demonstration of why the audit and threat-detection components of this project are necessary, and an example of monitoring data surfacing a security signal that was not deliberately sought.

## 7. Conclusion

The delivered stack satisfies each stated requirement: a metrics endpoint on the application, a dedicated Prometheus host scraping the application and node exporters, Grafana dashboards for latency, throughput and error rate, an alert rule triggered above 5 percent errors, container logs forwarded to CloudWatch, and CloudTrail and GuardDuty enabled with encrypted, lifecycle-managed storage.

Three changes would be required before the stack could be considered production-ready. TLS should terminate on both proxied ports, which was explicitly out of scope for this exercise. Grafana credentials should be sourced from AWS Secrets Manager rather than from Ansible group variables. Long-term metric retention should be handled through remote write, since a fifteen-day local time-series database cannot answer questions spanning a previous quarter.