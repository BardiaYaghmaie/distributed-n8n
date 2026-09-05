#!/usr/bin/env bash
# Creates the n8n owner account and imports n8n/workflow.json, so `make all` finishes with a live
# webhook instead of an empty n8n asking you to sign up.
#
# It talks to the same /rest API the editor UI uses. Logging in returns a session cookie, and
# curl saves that cookie to a file so the later calls can send it back.
set -euo pipefail
cd "$(dirname "$0")/.."
# shellcheck source=scripts/common.sh
. scripts/common.sh
require_cluster

NAMESPACE="n8n"
BASE_URL="${N8N_BASE_URL:-http://n8n.localtest.me}"

# Where curl keeps the session cookie between calls. Deleted at the end -- it is a live login.
COOKIES="/tmp/n8n-seed-cookies.txt"
rm -f "$COOKIES"

# The login n8n will use, from the Secret scripts/30-secrets.sh generated.
EMAIL=$(kubectl -n "$NAMESPACE" get secret n8n-app -o jsonpath='{.data.email}' | base64 --decode)
PASSWORD=$(kubectl -n "$NAMESPACE" get secret n8n-app -o jsonpath='{.data.password}' | base64 --decode)

echo "==> waiting for n8n to answer at ${BASE_URL}"
# The pod is Ready before the Ingress has finished routing to it, so poll rather than assume.
for i in $(seq 1 60); do
  curl -sf -o /dev/null "${BASE_URL}/healthz" && break
  [ "$i" -eq 60 ] && { echo "n8n did not answer at ${BASE_URL}" >&2; exit 1; }
  sleep 5
done

# On a brand-new database n8n has no users and wants a signup; on an existing one it wants a
# login. Ask which, rather than guessing and handling the error.
echo "==> signing in as ${EMAIL}"
NEEDS_SETUP=$(curl -sf "${BASE_URL}/rest/settings" \
  | python3 -c "import json,sys; print(json.load(sys.stdin)['data']['userManagement']['showSetupOnFirstLoad'])")

# The password comes from `openssl rand -base64`, whose characters are only A-Z a-z 0-9 + / = --
# none of which need escaping inside a JSON string, so it can be written in directly.
if [ "$NEEDS_SETUP" = "True" ]; then
  echo "    creating the owner account"
  curl -sf -o /dev/null --cookie-jar "$COOKIES" -X POST "${BASE_URL}/rest/owner/setup" \
    -H 'Content-Type: application/json' \
    -d "{\"email\":\"${EMAIL}\",\"firstName\":\"Platform\",\"lastName\":\"Admin\",\"password\":\"${PASSWORD}\"}"
else
  echo "    logging in to the existing account"
  curl -sf -o /dev/null --cookie-jar "$COOKIES" -X POST "${BASE_URL}/rest/login" \
    -H 'Content-Type: application/json' \
    -d "{\"emailOrLdapLoginId\":\"${EMAIL}\",\"password\":\"${PASSWORD}\"}"
fi

# If the cookie file has no n8n-auth line, the sign-in did not actually work and every call
# below would fail with a confusing 401 instead.
grep -q "n8n-auth" "$COOKIES" || { echo "FAIL: n8n did not return a session cookie" >&2; exit 1; }

WORKFLOW_NAME=$(python3 -c "import json; print(json.load(open('n8n/workflow.json'))['name'])")

# Delete any copy already there before importing. Two workflows cannot share a webhook path, so
# without this a second run would import a duplicate that n8n then refuses to activate.
echo "==> importing '${WORKFLOW_NAME}'"
OLD_ID=$(curl -sf --cookie "$COOKIES" "${BASE_URL}/rest/workflows" | python3 -c "
import json, sys
workflows = json.load(sys.stdin)['data']
print(next((w['id'] for w in workflows if w['name'] == '''${WORKFLOW_NAME}'''), ''))
")
if [ -n "$OLD_ID" ]; then
  echo "    removing the previous copy (id=${OLD_ID})"
  # n8n 2.x refuses to delete a workflow outright: "Workflow must be archived before it can be
  # deleted". Archiving also deactivates it, which is what frees up the webhook path.
  curl -sf -o /dev/null --cookie "$COOKIES" -X POST "${BASE_URL}/rest/workflows/${OLD_ID}/archive" \
    -H 'Content-Type: application/json' -d '{}'
  curl -sf -o /dev/null --cookie "$COOKIES" -X DELETE "${BASE_URL}/rest/workflows/${OLD_ID}"
fi

CREATED=$(curl -sf --cookie "$COOKIES" -X POST "${BASE_URL}/rest/workflows" \
  -H 'Content-Type: application/json' -d @n8n/workflow.json)

WORKFLOW_ID=$(echo "$CREATED" | python3 -c "import json,sys; print(json.load(sys.stdin)['data']['id'])")
# n8n stamps every save with a versionId and the activate call below refuses to run without the
# current one. It is in the create response, so there is no need to fetch the workflow again.
VERSION_ID=$(echo "$CREATED" | python3 -c "import json,sys; print(json.load(sys.stdin)['data']['versionId'])")
echo "    created (id=${WORKFLOW_ID})"

# Activating is what registers the webhook path. Until this succeeds, POSTing to /webhook/test
# returns 404. n8n ignores an "active": true field in the file, so it has to be a separate call.
echo "==> activating it"
curl -sf -o /dev/null --cookie "$COOKIES" -X POST "${BASE_URL}/rest/workflows/${WORKFLOW_ID}/activate" \
  -H 'Content-Type: application/json' -d "{\"versionId\":\"${VERSION_ID}\"}"

rm -f "$COOKIES"

echo
echo "    webhook: ${BASE_URL}/webhook/test"
echo "    editor:  ${BASE_URL}  (run 'make credentials' for the login)"
