#!/usr/bin/env bash
# apply-ism.sh
# Applies the ISM policy and index template to OpenSearch.
# Run AFTER OpenSearch is healthy.
set -euo pipefail

OPENSEARCH_URL="${OPENSEARCH_URL:-https://localhost:9200}"
USER="${OPENSEARCH_USER:-admin}"
PASS="${OPENSEARCH_PASS:-admin}"
CURL="curl -sk -u ${USER}:${PASS}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "==> [1/3] Waiting for OpenSearch to be ready..."
until $CURL "${OPENSEARCH_URL}/_cluster/health" | grep -qE '"status":"(green|yellow)"'; do
  echo "    ... waiting"
  sleep 5
done
echo "    OpenSearch is ready."

echo ""
echo "==> [2/3] Creating ISM policy 'sample-app-2day-retention'..."
RESPONSE=$($CURL -X PUT "${OPENSEARCH_URL}/_plugins/_ism/policies/sample-app-2day-retention" \
  -H "Content-Type: application/json" \
  -d @"${SCRIPT_DIR}/ism-policy.json")
echo "    Response: $RESPONSE"

echo ""
echo "==> [3/3] Applying index template 'sample-app-logs-template'..."
RESPONSE=$($CURL -X PUT "${OPENSEARCH_URL}/_index_template/sample-app-logs-template" \
  -H "Content-Type: application/json" \
  -d @"${SCRIPT_DIR}/index-template.json")
echo "    Response: $RESPONSE"

echo ""
echo "==> Done! Verifying policy attachment..."
echo ""
echo "--- ISM Policy ---"
$CURL "${OPENSEARCH_URL}/_plugins/_ism/policies/sample-app-2day-retention" | python3 -m json.tool 2>/dev/null || \
  $CURL "${OPENSEARCH_URL}/_plugins/_ism/policies/sample-app-2day-retention"

echo ""
echo "--- Index Template ---"
$CURL "${OPENSEARCH_URL}/_index_template/sample-app-logs-template" | python3 -m json.tool 2>/dev/null || \
  $CURL "${OPENSEARCH_URL}/_index_template/sample-app-logs-template"

echo ""
echo "==> To check policy on existing indices:"
echo "    curl -sk -u admin:admin ${OPENSEARCH_URL}/_plugins/_ism/explain/sample-app-logs-* | python3 -m json.tool"
