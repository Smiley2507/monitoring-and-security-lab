# Advanced Observability and Distributed Tracing

## Links

- Application and instrumentation: github.com/Smiley2507/jenkins-cicd-lab
- Observability platform: github.com/Smiley2507/monitoring-and-security-lab
- Evidence: screenshots directory in the observability platform repository

## Overview

A Flask weather service running on EC2 was extended with distributed tracing,
RED metrics and trace-correlated logging. The result is a single investigative
path: an alert names a symptom, Jaeger identifies the requests behind it, and
the trace ID retrieves the log lines for those requests from CloudWatch.

The work spans two repositories. Instrumentation lives with the application,
because it ships in the same image through the same pipeline. The tracing
backend, dashboards and alert rules live with the observability platform, which
is deployed independently and serves more than one application.

## How the signals flow

Prometheus scrapes application metrics every fifteen seconds. The application
exports spans to Jaeger over OTLP and writes structured logs to CloudWatch
through the Docker log driver. Prometheus evaluates alert rules and forwards
firing alerts to Alertmanager, which routes them to Discord.

The three signals answer different questions, and the trace ID is what joins
them: it is written into every log line at the moment the line is emitted, so
any trace can be matched to its own output.

## Instrumentation

The OpenTelemetry SDK is configured in a single application module.

Flask instrumentation creates a server span for each incoming request, recording
method, route and response status. Requests instrumentation creates a client
span for each outbound HTTP call, separating time spent waiting on the upstream
weather API from time spent inside the handler. Service name, version and
environment are attached to every span through an OpenTelemetry resource.

Spans are exported over OTLP HTTP to the monitoring host, in batches on a
background thread, so instrumentation adds no network round trip to the request
path. Tracing initialises only when the OTLP endpoint variable is set, which
keeps local runs and tests independent of the tracing backend.

RED metrics are exposed by the Prometheus Flask exporter. Rate and errors come
from a request counter labelled by HTTP status; duration comes from a histogram
of request durations. The endpoint is reachable only from inside the VPC,
enforced by the application's own nginx.

## Trace storage

Jaeger 2.20 runs on the existing monitoring host as an additional container in
the same Compose project, so no new instance was provisioned. Its configuration
is a single YAML file in the OpenTelemetry Collector format, declaring an OTLP
receiver, a batching processor and a storage exporter.

Spans are held in Badger, an embedded key-value store shipped inside the Jaeger
image, with 72-hour retention on local disk, so traces survive a container
restart. Jaeger publishes its own metrics in Prometheus format and Prometheus
scrapes them, placing the tracing backend under the same monitoring as
everything else.

Access is split by audience. The Jaeger interface is reachable only from the
operator's IP address, because a person uses it. The span ingest port is
reachable only from inside the VPC, because services use it and an open ingest
port would allow anyone to inject fabricated traces.

## Log correlation

A JSON log formatter reads the active span context each time a record is written
and attaches the trace ID and span ID as lowercase hexadecimal, matching how
Jaeger displays and searches them. When no span is active the fields are
omitted rather than zeroed, so an ID present in a log line is always a real one.

An after-request handler emits one JSON line per request carrying method, path,
status and trace ID. Logs are written to standard output and collected by the
Docker awslogs driver into CloudWatch.

## Dashboards and alerting

The Grafana dashboard carries three rows:

- **Application**: error rate, throughput, requests by status, p95 latency
- **Hosts**: CPU, memory and disk across all three servers
- **Traces**: the slowest traces and the traces marked as errors, queried
  directly from Jaeger

Two alert rules implement the required thresholds. The first fires when 5xx
responses exceed five per cent of traffic. The second fires when p95 latency
exceeds 300 milliseconds. Both require the condition to hold for ten minutes,
which separates a sustained fault from a momentary spike, and both include a
minimum request rate so that very low traffic cannot produce a misleading error
ratio from a near-zero denominator.

Alerts route through Alertmanager to Discord. Each notification carries the rule
name, the measured value, the affected instance, and links into Jaeger filtered
to this service and to error spans, into the Grafana dashboard, and into the
Prometheus alerts page.

## From symptom to root cause

| Stage | Where | What it establishes | Evidence |
| --- | --- | --- | --- |
| Symptom | Discord notification, Grafana | Which rule fired, the value, and when | 06, 07 |
| Trace | Jaeger, from the alert link | Which requests were affected, and which span failed or consumed the time | 08, 09 |
| Root cause | CloudWatch, filtered by trace ID | What the application was doing during that request | 10 |

Two fault paths validated the chain, both served by endpoints that exist only
when a test route flag is set.

**Errors.** Sustained requests to an endpoint returning HTTP 500 raised the
error rate above five per cent. The rule fired after ten minutes and the
notification reached Discord. Its Jaeger link returned the traces carrying an
error tag; opening one placed the failure inside the Flask server span rather
than in the outbound API call, distinguishing a fault in our code from a fault
in an upstream dependency. Filtering CloudWatch on that trace ID returned the
log lines for that single request.

**Latency.** Sustained requests to an endpoint delaying 800 milliseconds raised
p95 above the threshold. The same sequence followed, with the trace placing the
delay inside the handler.

Screenshots 09 and 10 show the same trace ID in Jaeger and in CloudWatch, which
is the evidence that the three signals describe one system.

## Verification

- **Metrics**: seven Prometheus targets healthy, including Jaeger's own; the
  metrics endpoint serves RED metrics and counts 5xx responses
- **Traces**: the application appears in Jaeger with server and client spans on
  every trace
- **Logs**: CloudWatch holds JSON lines carrying trace and span IDs
- **Alerting**: both rules load and evaluate, both were observed firing under
  induced load, and both cleared automatically when the load stopped

## Further work

- **Collector-based telemetry.** An OpenTelemetry Collector would give both
  signals one export path and allow metrics to move to OTLP. Prometheus could
  then store sample trace IDs alongside histogram buckets, letting a latency
  graph link straight to an example trace.
- **Grafana-native log correlation.** Adding Loki alongside CloudWatch would
  bring logs inside Grafana, turning the final step from a command line query
  into a click from the trace.
- **Bounded operation names.** OpenTelemetry names a server span after the
  matched route and falls back to the raw path when nothing matches, so
  automated scanning of the public host produces one operation name per probed
  URL. Rejecting known probe paths at nginx, or collapsing unmatched routes to a
  single span name, keeps the operation list proportional to the application.