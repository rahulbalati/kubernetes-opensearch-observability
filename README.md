# Kubernetes Observability Stack

A complete log pipeline on Kubernetes using OpenSearch, Fluent Bit, and ISM 2-day retention policy, deployed on a local kind cluster.

## Architecture

```
Sample App (log-generator)
        ↓
Fluent Bit (DaemonSet) — collects and ships logs
        ↓
OpenSearch Cluster (3 nodes) — stores and indexes logs
        ↓
ISM Policy — auto-deletes logs older than 2 days
```

## Repository Layout

```
k8s-observability/
├── fluent-bit/
│   └── fluent-bit.yaml
├── infrastructure/
│   ├── create-cluster.yaml
│   ├── ingress-controller.yaml
│   └── storage-class.yaml
├── ism-policy/
│   ├── index-template.json
│   └── ism-policy.json
├── opensearch/
│   └── opensearch-cluster.yaml
├── sample-app/
│   └── sample-app.yaml
└── README.md
```

---

## Prerequisites

| Tool | Install |
|------|---------|
| kubectl | https://kubernetes.io/docs/tasks/tools/ |
| helm | https://helm.sh/docs/intro/install/ |
| kind | https://kind.sigs.k8s.io/docs/user/quick-start/ |

---

## Deployment Steps

### Step 1 — Create the kind Cluster

```bash
kind create cluster --name observability --config=infrastructure/create-cluster.yaml
```

Verify:

```bash
kubectl cluster-info --context kind-observability
```

---

### Step 2 — Verify the Default StorageClass

```bash
kubectl get storageclass
```

Expected:
```
NAME                 PROVISIONER             DEFAULT
standard (default)   rancher.io/local-path   ✓
```

If no default StorageClass is present, apply it manually:

```bash
kubectl apply -f infrastructure/storage-class.yaml
```

---

### Step 3 — Deploy the nginx Ingress Controller

#### Option A — Via Helm 

```bash
helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx
helm repo update

helm install ingress-nginx ingress-nginx/ingress-nginx \
  --namespace ingress-nginx \
  --create-namespace \
  --wait
```

#### Option B — Via manifest [to explain kubernates concepts]

```bash
kubectl apply -f infrastructure/ingress-controller.yaml
```

Wait for it to be ready:

```bash
kubectl wait --namespace ingress-nginx \
  --for=condition=ready pod \
  --selector=app.kubernetes.io/component=controller \
  --timeout=120s
```


---

### Step 4 — Install cert-manager

The OpenSearch operator requires cert-manager for TLS.

```bash
kubectl apply -f https://github.com/cert-manager/cert-manager/releases/download/v1.14.5/cert-manager.yaml
```

Wait for it to be fully ready:

```bash
kubectl wait --namespace cert-manager \
  --for=condition=ready pod \
  --selector=app.kubernetes.io/instance=cert-manager \
  --timeout=120s
```

---

### Step 5 — Install the OpenSearch Operator

```bash
# Add the opensearch-operator Helm repo
helm repo add opensearch-operator https://opensearch-project.github.io/opensearch-k8s-operator/
helm repo update

# Install the operator into the logging namespace
helm install opensearch-operator opensearch-operator/opensearch-operator \
  --namespace logging \
  --create-namespace \
  --wait

# Confirm the operator pod is Running
kubectl get pods -n logging 
```

---

### Step 6 — Deploy the OpenSearch Cluster

```bash
kubectl apply -f opensearch/opensearch-cluster.yaml
```

Watch pods come up (takes 2-4 minutes):

```bash
kubectl get pods -n logging -w
```

Wait until you see:
```
opensearch-cluster-nodes-0             1/1   Running
opensearch-cluster-nodes-1             1/1   Running
opensearch-cluster-nodes-2             1/1   Running
opensearch-cluster-dashboards-xxxx     1/1   Running
```

Port-forward and verify cluster health:

```bash
kubectl port-forward svc/opensearch-cluster -n logging 9200:9200 &

curl -sk -u admin:'Admin@12345!' \
  https://localhost:9200/_cluster/health \
  | python3 -m json.tool
```

Expected: `"status": "green"` or `"status": "yellow"`

---

### Step 7 — Deploy the Sample Application

```bash
kubectl apply -f sample-app/sample-app.yaml
```

Verify logs are being generated:

```bash
kubectl logs -n sample-app \
  -l app.kubernetes.io/name=log-generator \
  -c log-generator \
  --tail=5
```

Expected:
```json
{"timestamp":"2026-03-08T10:00:01Z","level":"INFO","service":"auth","message":"Request processed","request_id":"req-00001","latency_ms":123}
```

---

### Step 8 — Deploy Fluent Bit

```bash
kubectl apply -f fluent-bit/fluent-bit.yaml
```

Verify pods are running:

```bash
kubectl get pods -n logging -l app.kubernetes.io/name=fluent-bit
```

Wait 30 seconds then confirm logs are arriving in OpenSearch:

```bash
curl -sk -u admin:'Admin@12345!' \
  "https://localhost:9200/sample-app-logs-*/_count" \
  | python3 -m json.tool
```

Expected: `"count"` greater than 0.

---

### Step 9 — Apply the 2-Day ISM Policy

#### Option A — Via manual 

#### 9a. Create the ISM Policy

```bash
curl -sk -u admin:'Admin@12345!' \
  -X PUT "https://localhost:9200/_plugins/_ism/policies/sample-app-2day-retention" \
  -H "Content-Type: application/json" \
  -d @ism-policy/ism-policy.json \
  | python3 -m json.tool
```

Expected: `"_id": "sample-app-2day-retention"`

---

#### 9b. Create the Index Template


```bash
curl -sk -u admin:'Admin@12345!' \
  -X PUT "https://localhost:9200/_index_template/sample-app-logs-template" \
  -H "Content-Type: application/json" \
  -d @ism-policy/index-template.json \
  | python3 -m json.tool
```

Expected: `"acknowledged": true`

---

#### 9c. Attach the Policy to the Existing Index

```bash
curl -sk -u admin:'Admin@12345!' \
  -X POST "https://localhost:9200/_plugins/_ism/add/sample-app-logs-$(date +%Y.%m.%d)" \
  -H "Content-Type: application/json" \
  -d '{"policy_id": "sample-app-2day-retention"}' \
  | python3 -m json.tool
```

Expected: `"updated_indices": 1, "failures": false`

---

#### Option B — Via script apply-ism.sh 

chmod +x ism-policy/apply-ism.sh

```bash 
OPENSEARCH_URL=https://localhost:9200 \
OPENSEARCH_USER=admin \
OPENSEARCH_PASS='Admin@12345!' \
  ./ism-policy/apply-ism.sh
```


### Step 10 — Verify Everything

#### ISM Policy exists

```bash
curl -sk -u admin:'Admin@12345!' \
  "https://localhost:9200/_plugins/_ism/policies/sample-app-2day-retention" \
  | python3 -m json.tool
```

#### ISM Policy attached to index

Wait 2-3 minutes after Step 9c, then run:

```bash
curl -sk -u admin:'Admin@12345!' \
  "https://localhost:9200/_plugins/_ism/explain/sample-app-logs-*" \
  | python3 -m json.tool
```

Expected:
```json
{
    "sample-app-logs-2026.03.08": {
        "policy_id": "sample-app-2day-retention",
        "enabled": true,
        "state": { "name": "hot" },
        "action": { "name": "rollover", "failed": false }
    },
    "total_managed_indices": 1
}
```

#### OpenSearch Dashboards (Visual Proof)

```bash
kubectl port-forward svc/opensearch-cluster-dashboards -n logging 5601:5601 &
```

Open http://localhost:5601 — login with `admin / Admin@12345!`

Navigate to: **Menu → Index Management → State management policies**

You will see `sample-app-2day-retention` listed with `sample-app-logs-*` pattern attached.


---

## Cleanup

```bash
kubectl delete -f sample-app/sample-app.yaml
kubectl delete -f fluent-bit/fluent-bit.yaml
kubectl delete opensearchclusters.opensearch.org opensearch-cluster -n logging
helm uninstall opensearch-operator -n logging
kubectl delete -f https://github.com/cert-manager/cert-manager/releases/download/v1.14.5/cert-manager.yaml
kubectl delete -f infrastructure/ingress-controller.yaml
kind delete cluster --name observability
```
