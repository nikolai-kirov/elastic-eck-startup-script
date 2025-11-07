#!/usr/bin/env bash
set -euo pipefail

# ---- Config (override via env if you want) ----
CLUSTER_NAME="${CLUSTER_NAME:-eck-kind}"
STACK_VERSION="${STACK_VERSION:-9.0.3}"   # Elastic stack version for ES/Kibana
NAMESPACE="${NAMESPACE:-elastic}"

# NodePort numbers mapped out of kind node to Windows localhost:
ES_NODEPORT=30920   # will be mapped to host 9200
KB_NODEPORT=30601   # will be mapped to host 5601

# ---- Helper ----
need() { command -v "$1" >/dev/null 2>&1 || { echo "❌ Missing: $1. Please install it and re-run."; exit 1; }; }

echo "🔎 Checking prerequisites..."
need docker
need kind
need kubectl
need helm

# Check Docker is actually running
if ! docker info >/dev/null 2>&1; then
  echo "❌ Docker daemon not reachable. Open Docker Desktop and ensure WSL integration is enabled."
  exit 1
fi

# ---- Create kind cluster (if not exists) with port mappings ----
if ! kind get clusters | grep -q "^${CLUSTER_NAME}$"; then
  echo "⛏️  Creating kind cluster: ${CLUSTER_NAME}"
  cat > /tmp/kind-${CLUSTER_NAME}.yaml <<EOF
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
nodes:
- role: control-plane
  kubeadmConfigPatches:
  - |
    kind: InitConfiguration
    nodeRegistration:
      kubeletExtraArgs:
        node-labels: "ingress-ready=true"
  extraPortMappings:
  - containerPort: ${KB_NODEPORT}
    hostPort: 5601
    protocol: TCP
  - containerPort: ${ES_NODEPORT}
    hostPort: 9200
    protocol: TCP
# Optional: raise default resources a touch for stability
# featureGates / runtimeConfig not needed for ECK basics
EOF
  kind create cluster --name "${CLUSTER_NAME}" --config /tmp/kind-${CLUSTER_NAME}.yaml
else
  echo "ℹ️  kind cluster '${CLUSTER_NAME}' already exists; reusing."
fi

# ---- Install ECK operator via Helm ----
echo "📦 Installing ECK operator (Helm) in elastic-system..."
helm repo add elastic https://helm.elastic.co >/dev/null
helm repo update >/dev/null
helm upgrade --install eck-operator elastic/eck-operator \
  --namespace elastic-system \
  --create-namespace

kubectl create namespace ${NAMESPACE}

echo "⏳ Waiting for ECK operator to be ready..."
kubectl rollout status sts/elastic-operator -n elastic-system --timeout=180s

# ---- Deploy Elasticsearch (1 node) ----
echo "🧰 Deploying Elasticsearch ${STACK_VERSION} (NodePort ${ES_NODEPORT} -> localhost:9200)..."
cat <<EOF | kubectl apply -f -
apiVersion: elasticsearch.k8s.elastic.co/v1
kind: Elasticsearch
metadata:
  name: elasticsearch
  namespace: ${NAMESPACE}
spec:
  version: "${STACK_VERSION}"
  http:
    service:
      spec:
        type: NodePort
        ports:
        - name: https
          port: 9200
          targetPort: 9200
          nodePort: ${ES_NODEPORT}
  nodeSets:
  - name: default
    count: 1
    config:
      node.store.allow_mmap: false
    podTemplate:
      spec:
        containers:
        - name: elasticsearch
          resources:
            requests:
              cpu: "500m"
              memory: "2Gi"
            limits:
              cpu: "2"
              memory: "4Gi"
EOF

# ---- Deploy Kibana ----
echo "🧰 Deploying Kibana ${STACK_VERSION} (NodePort ${KB_NODEPORT} -> localhost:5601)..."
cat <<EOF | kubectl apply -f -
apiVersion: kibana.k8s.elastic.co/v1
kind: Kibana
metadata:
  name: kibana
  namespace: ${NAMESPACE}
spec:
  version: "${STACK_VERSION}"
  count: 1
  elasticsearchRef:
    name: elasticsearch
  http:
    service:
      spec:
        type: NodePort
        ports:
        - name: https
          port: 5601
          targetPort: 5601
          nodePort: ${KB_NODEPORT}
EOF

# ---- Wait for ES to be healthy ----
echo "⏳ Waiting for Elasticsearch health to be green (this can take a few minutes)..."
for i in {1..180}; do
  health="$(kubectl get elasticsearch elasticsearch -n "${NAMESPACE}" -o jsonpath='{.status.health}' 2>/dev/null || true)"
  if [[ "${health}" == "green" ]]; then
    echo "✅ Elasticsearch is green."
    break
  fi
  sleep 2
  if [[ $i -eq 180 ]]; then
    echo "⚠️ Timed out waiting for Elasticsearch to be green. Current status: '${health:-unknown}'"
  fi
done

# ---- Wait for Kibana to be ready ----
echo "⏳ Waiting for Kibana to be ready..."
kubectl rollout status deployment/kibana-kb -n "${NAMESPACE}" --timeout=300s || true

# ---- Print credentials and endpoints ----
echo
echo "🔐 Fetching 'elastic' superuser password..."
ELASTIC_PW="$(kubectl get secret elasticsearch-es-elastic-user -n "${NAMESPACE}" -o go-template='{{.data.elastic | base64decode}}')"
echo "elastic password: ${ELASTIC_PW}"
echo

cat <<MSG
🎉 All set!

Endpoints (from Windows or WSL):
  • Elasticsearch: https://localhost:9200
  • Kibana:        https://localhost:5601

Login:
  • user: elastic
  • pass: ${ELASTIC_PW}

Notes:
  • Certificates are self-signed → your browser/clients may prompt to proceed.
  • To delete everything:
        kind delete cluster --name "${CLUSTER_NAME}"
MSG

