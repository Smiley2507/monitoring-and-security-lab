# Ansible — observability

Configures all three hosts. The playbook spans **both** stacks: the app and
Jenkins hosts belong to the CI/CD repository, and node_exporter has to run
there too.

```
ansible.cfg              dynamic inventory + the CI/CD stack's SSH key
inventory.aws_ec2.yml    filters on BOTH Project tags, groups by Role
group_vars/all.yml       pinned image versions, credentials, paths
site.yml                 three plays, in dependency order
roles/node_exporter/     binary + systemd unit, on every host
roles/app_exporters/     cAdvisor + nginx-exporter on the app server
roles/monitoring/        Prometheus, Grafana, cAdvisor, nginx on the new host
```

## Usage

```bash
ansible-galaxy collection install -r requirements.yml
ansible-inventory --graph        # expect role_app, role_jenkins, role_monitoring
ansible all -m ping
ansible-playbook site.yml
```

## Why the plays are ordered this way

`monitoring` runs **last** on purpose. The Prometheus target files are
generated from inventory facts, so every host must have been discovered before
they are written.

## Design notes

**node_exporter is a binary, not a container.** A containerised node_exporter
reports the container's view of `/proc` and `/sys` unless you mount the host
filesystem and pass `--path.rootfs`, and even then some metrics stay wrong. A
static binary with a systemd unit avoids the whole class of problem, and means
the Jenkins host does not depend on Docker to be monitored.

**The app's exporters are a separate compose project** (`/opt/monitoring-agents`)
from the weather-app stack (`/opt/weather-app`). A redeploy of the application
never disturbs the exporters, and this repository never edits a file the CI/CD
repository owns.

**nginx-exporter uses `network_mode: host`** so its scrape of `/stub_status`
comes from `127.0.0.1`. On a bridge network the source address would be a
Docker `172.x` address and the allow-list in the app's nginx config would
return 403.

**Prometheus targets are file_sd, not static_configs.** `prometheus.yml` stays
static — it is a submitted deliverable — while the addresses live in
`/etc/prometheus/targets/*.json`, generated from the EC2 inventory. Prometheus
watches that directory and re-reads it without a restart, so rebuilding the
infrastructure needs one playbook run and no config edit.

## Credentials

`group_vars/all.yml` holds lab-grade defaults for the Grafana admin password
and the Prometheus basic-auth password. **Change them.** In anything real they
belong in `ansible-vault`:

```bash
ansible-vault encrypt_string 'realpassword' --name 'grafana_admin_password'
```
