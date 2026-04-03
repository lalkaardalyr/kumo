#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"

CLUSTER_NAME="${CLUSTER_NAME:-kumo-e2e}"
KUMO_IMAGE="${KUMO_IMAGE:-ghcr.io/sivchari/kumo:e2e-local}"
ACK_SQS_CHART_VERSION="${ACK_SQS_CHART_VERSION:-1.4.1}"
QUEUE_NAME="helm-e2e-$(date +%s)"

KUMO_NS="kumo-system"
ACK_NS="ack-system"
QUEUE_NS="ack-test"
KUMO_RELEASE="kumo"
ACK_RELEASE="ack-sqs-controller"
KUMO_ENDPOINT="http://${KUMO_RELEASE}.${KUMO_NS}.svc.cluster.local:4566"
ACK_LABEL="app.kubernetes.io/instance=${ACK_RELEASE}"
LOCAL_ENDPOINT="http://127.0.0.1:14566"

export AWS_ACCESS_KEY_ID=test
export AWS_SECRET_ACCESS_KEY=test
export AWS_DEFAULT_REGION=us-east-1
export AWS_ENDPOINT_URL="$LOCAL_ENDPOINT"

KUBECTL=(kubectl --context "kind-${CLUSTER_NAME}")
PORT_FORWARD_PID=""
PORT_FORWARD_LOG=""

cleanup() {
  if [[ -n "$PORT_FORWARD_PID" ]]; then
    kill "$PORT_FORWARD_PID" >/dev/null 2>&1 || true
  fi
  if [[ -n "$PORT_FORWARD_LOG" ]]; then
    rm -f "$PORT_FORWARD_LOG"
  fi
  kind delete cluster --name "$CLUSTER_NAME" >/dev/null 2>&1 || true
}

start_port_forward() {
  local i
  PORT_FORWARD_LOG="$(mktemp)"

  "${KUBECTL[@]}" port-forward -n "$KUMO_NS" "svc/${KUMO_RELEASE}" 14566:4566 >"$PORT_FORWARD_LOG" 2>&1 &
  PORT_FORWARD_PID=$!

  for i in $(seq 1 30); do
    if curl -fs "${LOCAL_ENDPOINT}/health" >/dev/null 2>&1; then
      return 0
    fi
    if ! kill -0 "$PORT_FORWARD_PID" >/dev/null 2>&1; then
      cat "$PORT_FORWARD_LOG"
      return 1
    fi
    sleep 1
  done

  cat "$PORT_FORWARD_LOG"
  return 1
}

wait_for_queue_url() {
  local queue_url=""
  local terminal=""
  local i

  for i in $(seq 1 90); do
    queue_url="$("${KUBECTL[@]}" get queue -n "$QUEUE_NS" "$QUEUE_NAME" -o jsonpath='{.status.queueURL}' 2>/dev/null || true)"
    if [[ -n "$queue_url" ]]; then
      printf '%s\n' "$queue_url"
      return 0
    fi

    terminal="$("${KUBECTL[@]}" get queue -n "$QUEUE_NS" "$QUEUE_NAME" -o jsonpath='{.status.conditions[?(@.type=="ACK.Terminal")].status}' 2>/dev/null || true)"
    if [[ "$terminal" == "True" ]]; then
      "${KUBECTL[@]}" get queue -n "$QUEUE_NS" "$QUEUE_NAME" -o yaml
      return 1
    fi

    sleep 2
  done

  "${KUBECTL[@]}" get queue -n "$QUEUE_NS" "$QUEUE_NAME" -o yaml || true
  return 1
}

main() {
  local endpoint=""
  local queue_url=""
  local resolved_queue_url=""
  local queue_tag=""
  local message_id=""
  local message_body=""
  local queue_count=""
  local list_queues_output=""
  local i

  trap cleanup EXIT

  command -v kind >/dev/null
  command -v helm >/dev/null
  command -v kubectl >/dev/null
  command -v docker >/dev/null
  command -v jq >/dev/null
  command -v aws >/dev/null
  command -v curl >/dev/null

  echo "Build kumo image"
  docker build -f "$REPO_ROOT/docker/Dockerfile" -t "$KUMO_IMAGE" "$REPO_ROOT"

  kind delete cluster --name "$CLUSTER_NAME" >/dev/null 2>&1 || true
  kind create cluster --name "$CLUSTER_NAME" --wait 60s
  kind load docker-image "$KUMO_IMAGE" --name "$CLUSTER_NAME"

  echo "Install Kyverno"
  helm repo add kyverno https://kyverno.github.io/kyverno/ --force-update >/dev/null
  helm install kyverno kyverno/kyverno \
    -n kyverno \
    --create-namespace \
    --set admissionController.replicas=2 \
    --set backgroundController.enabled=false \
    --set cleanupController.enabled=false \
    --set reportsController.enabled=false \
    --set features.policyExceptions.enabled=true \
    --wait \
    --timeout 3m
  "${KUBECTL[@]}" wait --for=condition=Established "crd/clusterpolicies.kyverno.io" --timeout=120s >/dev/null

  echo "Install kumo chart"
  helm install "$KUMO_RELEASE" "$REPO_ROOT/charts/kumo" \
    -n "$KUMO_NS" \
    --create-namespace \
    --set injection.enabled=true \
    --set injection.namespaceLabelKey=sivchari.github.io/kumo-inject \
    --set injection.namespaceLabelValue=enabled \
    --set kumo.image.tag=e2e-local \
    --wait \
    --timeout 2m
  "${KUBECTL[@]}" rollout status "statefulset/${KUMO_RELEASE}" -n "$KUMO_NS" --timeout=120s

  echo "Install ACK SQS controller"
  "${KUBECTL[@]}" create namespace "$ACK_NS" --dry-run=client -o yaml | "${KUBECTL[@]}" apply -f -
  "${KUBECTL[@]}" label namespace "$ACK_NS" sivchari.github.io/kumo-inject=enabled --overwrite >/dev/null
  helm install "$ACK_RELEASE" oci://public.ecr.aws/aws-controllers-k8s/sqs-chart \
    -n "$ACK_NS" \
    --version "$ACK_SQS_CHART_VERSION" \
    --set aws.region=us-east-1 \
    --set aws.allow_unsafe_aws_endpoint_urls=true \
    --wait \
    --timeout 3m
  "${KUBECTL[@]}" wait --for=condition=Established "crd/queues.sqs.services.k8s.aws" --timeout=120s >/dev/null
  "${KUBECTL[@]}" wait --for=condition=ready pod -l "$ACK_LABEL" -n "$ACK_NS" --timeout=180s >/dev/null

  endpoint="$("${KUBECTL[@]}" get pod -n "$ACK_NS" -l "$ACK_LABEL" -o jsonpath='{range .items[0].spec.containers[?(@.name=="controller")].env[?(@.name=="AWS_ENDPOINT_URL")]}{.value}{end}')"
  if [[ "$endpoint" != "$KUMO_ENDPOINT" ]]; then
    echo "ERROR: ACK controller AWS_ENDPOINT_URL mismatch. expected=${KUMO_ENDPOINT} actual=${endpoint}" >&2
    "${KUBECTL[@]}" get pod -n "$ACK_NS" -l "$ACK_LABEL" -o yaml
    exit 1
  fi

  start_port_forward

  echo "Create ACK queue"
  "${KUBECTL[@]}" create namespace "$QUEUE_NS" --dry-run=client -o yaml | "${KUBECTL[@]}" apply -f -
  cat <<EOF | "${KUBECTL[@]}" apply -f -
apiVersion: sqs.services.k8s.aws/v1alpha1
kind: Queue
metadata:
  name: ${QUEUE_NAME}
  namespace: ${QUEUE_NS}
spec:
  queueName: ${QUEUE_NAME}
  tags:
    purpose: helm-e2e
EOF

  queue_url="$(wait_for_queue_url)"
  resolved_queue_url="$(aws sqs get-queue-url --queue-name "$QUEUE_NAME" --output json | jq -r '.QueueUrl // empty')"
  if [[ "$resolved_queue_url" != "$queue_url" ]]; then
    echo "ERROR: queue URL mismatch between Queue.status and sqs get-queue-url. status=${queue_url} get-queue-url=${resolved_queue_url}" >&2
    exit 1
  fi

  queue_tag="$(aws sqs list-queue-tags --queue-url "$queue_url" --output json | jq -r '.Tags.purpose // empty')"
  if [[ "$queue_tag" != "helm-e2e" ]]; then
    echo "ERROR: queue tag 'purpose' mismatch. expected=helm-e2e actual=${queue_tag}" >&2
    exit 1
  fi

  message_id="$(aws sqs send-message --queue-url "$queue_url" --message-body "hello from ACK" --output json | jq -r '.MessageId // empty')"
  if [[ -z "$message_id" ]]; then
    echo "ERROR: aws sqs send-message returned empty MessageId for queue=${queue_url}" >&2
    exit 1
  fi

  message_body="$(aws sqs receive-message --queue-url "$queue_url" --max-number-of-messages 1 --wait-time-seconds 1 --output json | jq -r '.Messages[0].Body // empty')"
  if [[ "$message_body" != "hello from ACK" ]]; then
    echo "ERROR: received message body mismatch. expected='hello from ACK' actual='${message_body}'" >&2
    exit 1
  fi

  echo "Delete ACK queue"
  "${KUBECTL[@]}" delete "queue/${QUEUE_NAME}" -n "$QUEUE_NS" >/dev/null
  "${KUBECTL[@]}" wait --for=delete "queue/${QUEUE_NAME}" -n "$QUEUE_NS" --timeout=180s >/dev/null

  for i in $(seq 1 60); do
    list_queues_output="$(aws sqs list-queues --queue-name-prefix "$QUEUE_NAME" --output json || true)"
    if [[ -z "$list_queues_output" ]]; then
      queue_count="0"
    else
      queue_count="$(jq '.QueueUrls // [] | length' <<<"$list_queues_output")"
    fi
    if [[ "$queue_count" == "0" ]]; then
      echo "Helm e2e passed"
      return 0
    fi
    sleep 2
  done

  exit 1
}

main "$@"
