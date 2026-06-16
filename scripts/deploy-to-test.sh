#!/usr/bin/env bash
# Deploy redmine_merge_request_links to the Ackee test Redmine instance
# (redmine-upgrade.ack.ee). Modeled on redmine-plugin-notifications'
# scripts/deploy-to-test.sh.
#
# Flow:
#   1. Find the redmine-test pod in the given namespace.
#   2. Clear any previous copy of our plugin on the data PVC.
#   3. Copy only the runtime files (init.rb, app, lib, config, db, assets) onto the PVC.
#   4. Re-apply the zeitwerk require shims (this plugin predates zeitwerk and
#      will NOT boot on Redmine 5.1.x without them — see handover §3).
#   5. Rsync the plugin into Redmine's plugins/ dir (data/ → redmine/plugins/).
#   6. Run plugin migrations (creates merge_requests / issues_merge_requests on first deploy).
#   7. Restart the deployment (Recreate strategy → clean RWO-PVC reattach).
#   8. Wait for rollout, poll until the plugin registers, and warn if the
#      REDMINE_MERGE_REQUEST_LINKS_* env vars the fix depends on are absent.
#
# Usage:
#   ./scripts/deploy-to-test.sh
#   NAMESPACE=production LABEL_SELECTOR=app=redmine-test ./scripts/deploy-to-test.sh
#
# Prerequisites: kubectl configured for the ackee-production cluster, with
# permission to exec into the production namespace:
#   gcloud container clusters get-credentials ackee-production-50479 \
#     --region europe-west1-d --project ackee-production
#
# ⚠️ ZEITWERK SHIM (apply_zeitwerk_shims below) is RECONSTRUCTED from handover
# §3 — the real shim lives only as an *uncommitted* edit on the prod PVC and
# could not be read for this script (prod read was not authorized). VERIFY it
# against the prod PVC's actual init.rb / lib/redmine_merge_request_links.rb
# before trusting a prod deploy. If the shim is wrong the plugin will fail to
# boot; step 8 polls for registration and aborts loudly rather than leaving a
# silently-broken instance.
set -euo pipefail

NAMESPACE="${NAMESPACE:-production}"
LABEL_SELECTOR="${LABEL_SELECTOR:-app=redmine-test}"
DEPLOYMENT="${DEPLOYMENT:-deployment/redmine-test}"
PLUGIN_NAME="redmine_merge_request_links"
PLUGIN_DIR="/home/redmine/data/plugins/${PLUGIN_NAME}"
APP_PLUGIN_DIR="/home/redmine/redmine/plugins/${PLUGIN_NAME}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

# Runtime-only files; everything else in the repo (docs, scripts, tests, bin/,
# patches/, .git, etc.) stays on the host. db/migrate is included so
# `rake redmine:plugins:migrate` can pick up schema changes; assets/ carries
# the stylesheet the issue-box view hook references.
RUNTIME_PATHS=(init.rb app lib config db assets)

# Required env vars on the Deployment for the merge→webhook flow to do anything.
# The plugin still boots without them, but the "Test ready" transition + webhook
# is inert, so we warn rather than fail.
REQUIRED_ENV=(
  REDMINE_MERGE_REQUEST_LINKS_REDMINE_USER_ID
  REDMINE_MERGE_REQUEST_LINKS_AFTER_MERGE_STATUS
  REDMINE_MERGE_REQUEST_LINKS_GITLAB_WEBHOOK_TOKEN
)

log() { printf '==> %s\n' "$*" >&2; }

# Re-apply the zeitwerk compatibility shims to the freshly-copied plugin on the
# PVC. Because step 2 wipes and step 3 re-copies pristine repo files every run,
# these substitutions always apply to clean input — no idempotency dance needed.
# Each substitution is verified; a missing expected line aborts the deploy.
apply_zeitwerk_shims() {
  local pod="$1"

  log "Applying zeitwerk shims (init.rb: ignore lib/ + relative require)..."
  kubectl exec -n "$NAMESPACE" "$pod" -- bash -lc "
    set -euo pipefail
    cd '$PLUGIN_DIR'

    grep -qxF \"require 'redmine_merge_request_links'\" init.rb \
      || { echo \"ERROR: init.rb does not contain the expected top-level require; shim out of date\" >&2; exit 1; }
    perl -0pi -e \"s{^require 'redmine_merge_request_links'\\$}{Rails.autoloaders.main.ignore(File.dirname(__FILE__) + '/lib')\\nrequire File.dirname(__FILE__) + '/lib/redmine_merge_request_links'}m\" init.rb
    grep -qF \"require File.dirname(__FILE__) + '/lib/redmine_merge_request_links'\" init.rb \
      || { echo \"ERROR: init.rb shim did not apply\" >&2; exit 1; }

    grep -qxF \"require 'redmine_merge_request_links/hooks'\" lib/redmine_merge_request_links.rb \
      || { echo \"ERROR: lib/redmine_merge_request_links.rb does not contain the expected require; shim out of date\" >&2; exit 1; }
    perl -0pi -e \"s{^require 'redmine_merge_request_links/hooks'\\$}{require File.dirname(__FILE__) + '/redmine_merge_request_links/hooks'}m\" lib/redmine_merge_request_links.rb
    grep -qF \"require File.dirname(__FILE__) + '/redmine_merge_request_links/hooks'\" lib/redmine_merge_request_links.rb \
      || { echo \"ERROR: lib shim did not apply\" >&2; exit 1; }
  "
}

cd "$ROOT"

log "Checking kubectl context..."
ctx="$(kubectl config current-context 2>/dev/null || true)"
if [ -z "$ctx" ]; then
  echo "ERROR: no kubectl current-context. Run 'gcloud container clusters get-credentials ackee-production-50479 --region europe-west1-d --project ackee-production' first." >&2
  exit 1
fi
log "Context: $ctx"

log "Finding pod in $NAMESPACE matching $LABEL_SELECTOR..."
pod="$(kubectl get pod -n "$NAMESPACE" -l "$LABEL_SELECTOR" \
       --field-selector=status.phase=Running \
       -o jsonpath='{.items[*].metadata.name}')"
read -ra pod_arr <<< "$pod"
if [ ${#pod_arr[@]} -eq 0 ]; then
  echo "ERROR: no Running pods match $LABEL_SELECTOR in $NAMESPACE" >&2
  exit 1
elif [ ${#pod_arr[@]} -gt 1 ]; then
  echo "ERROR: multiple Running pods match $LABEL_SELECTOR (${pod_arr[*]}). Refusing to guess — re-run after rollout stabilises." >&2
  exit 1
fi
pod="${pod_arr[0]}"
log "Pod: $pod"

log "Clearing any previous plugin copy at $PLUGIN_DIR..."
kubectl exec -n "$NAMESPACE" "$pod" -- rm -rf "$PLUGIN_DIR"

# kubectl cp of a single file into .../init.rb fails if the parent dir doesn't
# exist (directory copies create it, file copies don't).
log "Creating $PLUGIN_DIR..."
kubectl exec -n "$NAMESPACE" "$pod" -- mkdir -p "$PLUGIN_DIR"

log "Copying runtime files onto the PVC..."
for src in "${RUNTIME_PATHS[@]}"; do
  if [ ! -e "$src" ]; then
    echo "ERROR: $src missing from repo root; aborting" >&2
    exit 1
  fi
  log "  kubectl cp $src -> $PLUGIN_DIR/$src"
  kubectl cp -n "$NAMESPACE" "$src" "$pod:$PLUGIN_DIR/$src"
done

apply_zeitwerk_shims "$pod"

log "Rsyncing plugin into Redmine's plugins/ dir (data/ → redmine/plugins/)..."
kubectl exec -n "$NAMESPACE" "$pod" -- \
  rsync -av --delete --chown=redmine:redmine \
    "$PLUGIN_DIR/" "$APP_PLUGIN_DIR/" \
  > /dev/null

log "Running plugin migrations..."
kubectl exec -n "$NAMESPACE" "$pod" -- \
  bash -lc "cd /home/redmine/redmine && bundle exec rake redmine:plugins:migrate NAME=${PLUGIN_NAME} RAILS_ENV=production"

log "Triggering rollout restart..."
kubectl rollout restart -n "$NAMESPACE" "$DEPLOYMENT"
kubectl rollout status  -n "$NAMESPACE" "$DEPLOYMENT" --timeout=5m

log "Verifying plugin loaded in the new pod..."
newpod="$(kubectl get pod -n "$NAMESPACE" -l "$LABEL_SELECTOR" \
          --field-selector=status.phase=Running \
          -o jsonpath='{.items[0].metadata.name}')"
log "New pod: $newpod"

# The deployment's livenessProbe has initialDelaySeconds: 600, so
# `kubectl rollout status` returns as soon as pods are marked Ready, even
# before Redmine's workers have finished booting (cold boot can take 3-10 min
# on this image). Poll the rails runner until the plugin list actually
# contains our plugin, with a 10-minute cap.
plugins=""
log "Polling for plugin registration (up to 10 min, cold boot is slow)..."
for _ in $(seq 1 60); do
  plugins="$(kubectl exec -n "$NAMESPACE" "$newpod" -- \
    bash -lc 'cd /home/redmine/redmine && bundle exec rails runner -e production "Redmine::Plugin.all.each { |p| puts %Q(#{p.id} #{p.version}) }" 2>/dev/null' \
    2>/dev/null || echo "")"
  if echo "$plugins" | grep -q "^${PLUGIN_NAME} "; then
    break
  fi
  printf '.' >&2
  sleep 10
done
printf '\n' >&2

echo "$plugins"
if ! echo "$plugins" | grep -q "^${PLUGIN_NAME} "; then
  echo "ERROR: ${PLUGIN_NAME} did not register within 10 minutes." >&2
  echo "Most likely the zeitwerk shim is wrong (see header) — check boot logs:" >&2
  echo "  kubectl logs -n $NAMESPACE $newpod --tail=200" >&2
  echo "  kubectl exec -n $NAMESPACE $newpod -- ls $PLUGIN_DIR" >&2
  exit 1
fi

log "Checking the merge→webhook env vars are configured on the pod..."
missing=()
for var in "${REQUIRED_ENV[@]}"; do
  if ! kubectl exec -n "$NAMESPACE" "$newpod" -- bash -lc "[ -n \"\${$var:-}\" ]"; then
    missing+=("$var")
  fi
done
if [ ${#missing[@]} -gt 0 ]; then
  echo "WARNING: missing env vars on the deployment: ${missing[*]}" >&2
  echo "         The plugin booted, but the 'Test ready' transition + webhook will be inert until these are set." >&2
fi

log "Deploy OK."
