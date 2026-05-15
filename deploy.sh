#!/usr/bin/env bash
# deploy.sh — build and deploy trinket-oss to Google Cloud Run
#
# Prerequisites:
#   gcloud CLI installed and authenticated (gcloud auth login)
#   Cloud Build, Cloud Run, Secret Manager, and Firestore APIs enabled
#
# Usage:
#   GCP_PROJECT=my-project ./deploy.sh
#
# All variables below can be overridden by exporting them before running.

set -euo pipefail

# ─── Configuration ─────────────────────────────────────────────────────────────
GCP_PROJECT="${GCP_PROJECT:-}"
GCP_REGION="${GCP_REGION:-us-central1}"
SERVICE_NAME="${SERVICE_NAME:-trinket}"
# Image is pushed to Artifact Registry (gcr.io still works as a redirect).
IMAGE="${IMAGE:-gcr.io/${GCP_PROJECT}/${SERVICE_NAME}}"
# Name of the Secret Manager secret that holds SESSION_PASSWORD.
SECRET_NAME="${SECRET_NAME:-trinket-session-password}"
# Cloud Run resource sizing.
MEMORY="${MEMORY:-512Mi}"
MAX_INSTANCES="${MAX_INSTANCES:-10}"

# ─── Validate ──────────────────────────────────────────────────────────────────
if [[ -z "$GCP_PROJECT" ]]; then
  echo "ERROR: GCP_PROJECT is not set."
  echo "  export GCP_PROJECT=my-gcp-project-id"
  exit 1
fi

echo "=================================================="
echo "  Project:      $GCP_PROJECT"
echo "  Region:       $GCP_REGION"
echo "  Service:      $SERVICE_NAME"
echo "  Image:        $IMAGE"
echo "=================================================="
echo ""

# ─── APIs ──────────────────────────────────────────────────────────────────────
# Enable required APIs (idempotent — safe to run on every deploy).
echo "Enabling required GCP APIs..."
gcloud services enable \
  run.googleapis.com \
  cloudbuild.googleapis.com \
  secretmanager.googleapis.com \
  firestore.googleapis.com \
  --project="$GCP_PROJECT" \
  --quiet

# ─── Firestore database ────────────────────────────────────────────────────────
# Create the default Firestore Native database if it doesn't exist yet.
# This is idempotent — gcloud prints a warning and exits 0 if it already exists.
echo "Ensuring Firestore Native database exists..."
gcloud firestore databases create \
  --location="$GCP_REGION" \
  --type=firestore-native \
  --project="$GCP_PROJECT" \
  --quiet 2>/dev/null || true

# ─── Session-password secret ───────────────────────────────────────────────────
echo "Checking session-password secret..."
if ! gcloud secrets describe "$SECRET_NAME" \
    --project="$GCP_PROJECT" &>/dev/null; then
  echo ""
  echo "Secret '$SECRET_NAME' not found. Creating it now."
  echo "Enter a SESSION_PASSWORD (min 32 characters — input is hidden):"
  read -rs SESSION_PW
  echo
  if [[ ${#SESSION_PW} -lt 32 ]]; then
    echo "ERROR: Password must be at least 32 characters."
    exit 1
  fi
  printf '%s' "$SESSION_PW" | gcloud secrets create "$SECRET_NAME" \
    --data-file=- \
    --project="$GCP_PROJECT" \
    --replication-policy=automatic
  echo "Secret created."
else
  echo "Secret '$SECRET_NAME' already exists."
fi

# ─── IAM ───────────────────────────────────────────────────────────────────────
# Grant the Cloud Run default compute service account access to:
#   1. The session-password secret
#   2. Firestore (datastore.user covers Firestore Native)
#
# If you're using a custom --service-account for Cloud Run, replace the SA below.
echo "Granting IAM roles to the Cloud Run service account..."
PROJECT_NUMBER=$(gcloud projects describe "$GCP_PROJECT" \
  --format="value(projectNumber)")
CLOUD_RUN_SA="${PROJECT_NUMBER}-compute@developer.gserviceaccount.com"

gcloud secrets add-iam-policy-binding "$SECRET_NAME" \
  --project="$GCP_PROJECT" \
  --member="serviceAccount:${CLOUD_RUN_SA}" \
  --role="roles/secretmanager.secretAccessor" \
  --quiet

gcloud projects add-iam-policy-binding "$GCP_PROJECT" \
  --member="serviceAccount:${CLOUD_RUN_SA}" \
  --role="roles/datastore.user" \
  --quiet

# ─── Build ─────────────────────────────────────────────────────────────────────
echo ""
echo "Building image with Cloud Build..."
gcloud builds submit \
  --tag "$IMAGE" \
  --project="$GCP_PROJECT" \
  .

# ─── Get current service URL (if service already exists) ───────────────────────
EXISTING_URL=""
if gcloud run services describe "$SERVICE_NAME" \
    --region="$GCP_REGION" \
    --project="$GCP_PROJECT" &>/dev/null 2>&1; then
  EXISTING_URL=$(gcloud run services describe "$SERVICE_NAME" \
    --region="$GCP_REGION" \
    --project="$GCP_PROJECT" \
    --format="value(status.url)")
fi

# ─── Build the env-vars file ───────────────────────────────────────────────────
# We write env vars to a temp YAML file so that the NODE_CONFIG JSON value
# (which contains commas and colons) is passed safely without shell escaping.
ENV_VARS_FILE=$(mktemp /tmp/trinket-cloudrun-env-XXXXXX.yaml)
trap 'rm -f "$ENV_VARS_FILE"' EXIT

SERVICE_HOSTNAME="${EXISTING_URL#https://}"

cat > "$ENV_VARS_FILE" <<YAML
NODE_ENV: production
NODE_APP_INSTANCE: cloudrun
GOOGLE_CLOUD_PROJECT: ${GCP_PROJECT}
NODE_CONFIG: '{"app":{"url":{"hostname":"${SERVICE_HOSTNAME}"}}}'
YAML

# ─── Deploy ────────────────────────────────────────────────────────────────────
echo ""
echo "Deploying to Cloud Run..."
gcloud run deploy "$SERVICE_NAME" \
  --image="$IMAGE" \
  --region="$GCP_REGION" \
  --project="$GCP_PROJECT" \
  --platform=managed \
  --allow-unauthenticated \
  --memory="$MEMORY" \
  --min-instances=0 \
  --max-instances="$MAX_INSTANCES" \
  --env-vars-file="$ENV_VARS_FILE" \
  --set-secrets="SESSION_PASSWORD=${SECRET_NAME}:latest"

# ─── Post-deploy: wire up the hostname ─────────────────────────────────────────
FINAL_URL=$(gcloud run services describe "$SERVICE_NAME" \
  --region="$GCP_REGION" \
  --project="$GCP_PROJECT" \
  --format="value(status.url)")

FINAL_HOSTNAME="${FINAL_URL#https://}"

if [[ -z "$EXISTING_URL" ]]; then
  # First deploy — the URL wasn't known during the deploy above, so NODE_CONFIG
  # had an empty hostname. Patch it now with a fast metadata-only update
  # (no container rebuild needed).
  echo ""
  echo "First deploy complete. Patching hostname in NODE_CONFIG..."
  PATCH_FILE=$(mktemp /tmp/trinket-cloudrun-env-XXXXXX.yaml)
  trap 'rm -f "$ENV_VARS_FILE" "$PATCH_FILE"' EXIT
  cat > "$PATCH_FILE" <<YAML
NODE_ENV: production
NODE_APP_INSTANCE: cloudrun
GOOGLE_CLOUD_PROJECT: ${GCP_PROJECT}
NODE_CONFIG: '{"app":{"url":{"hostname":"${FINAL_HOSTNAME}"}}}'
YAML
  gcloud run services update "$SERVICE_NAME" \
    --region="$GCP_REGION" \
    --project="$GCP_PROJECT" \
    --env-vars-file="$PATCH_FILE"
fi

# ─── Done ──────────────────────────────────────────────────────────────────────
echo ""
echo "=================================================="
echo "  Deployed: ${FINAL_URL}"
echo "=================================================="
echo ""
echo "Next steps:"
echo "  1. Verify the app: curl ${FINAL_URL}/"
echo "  2. Test auth:      curl ${FINAL_URL}/login"
echo "  3. Check logs:     gcloud run services logs read $SERVICE_NAME \\"
echo "                       --region=$GCP_REGION --project=$GCP_PROJECT"
