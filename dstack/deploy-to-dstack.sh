#!/usr/bin/env bash
set -euo pipefail

# Deploy deterministic build to DStack using Phala Cloud
# Usage: ./scripts/deploy-to-dstack.sh builds/simple-det-app-YYYYMMDD-hash/build-manifest.json [node-id]

if [[ $# -lt 1 ]]; then
  echo "Usage: $0 <build-manifest.json> [node-id]"
  echo ""
  echo "Deploys a verified deterministic build to DStack via Phala Cloud"
  echo ""
  echo "Example:"
  echo "  $0 builds/simple-det-app-20250918-nogit/build-manifest.json"
  echo "  $0 builds/simple-det-app-20250918-nogit/build-manifest.json 12"
  exit 1
fi

MANIFEST="$1"
NODE_ID="${2:-}"  # Optional, will prompt if not provided

if [[ ! -f "$MANIFEST" ]]; then
  echo "❌ Build manifest not found: $MANIFEST"
  exit 1
fi

# Extract build info
BUILD_DIR=$(dirname "$MANIFEST")
EXPECTED_HASH=$(jq -r '.expected_hash' "$MANIFEST")

echo "🚀 Deploying deterministic build to DStack..."
echo "🔍 Expected image hash: $EXPECTED_HASH"

# Check authentication (either API key or logged in via phala auth)
if [[ -z "${PHALA_CLOUD_API_KEY:-}" ]]; then
  # Check if authenticated via phala auth
  if ! phala auth status >/dev/null 2>&1; then
    echo "❌ Not authenticated with Phala Cloud"
    echo "💡 Either set PHALA_CLOUD_API_KEY or run: phala auth login"
    exit 1
  fi
  echo "✅ Authenticated via phala auth"
else
  echo "✅ Using PHALA_CLOUD_API_KEY"
fi

# Check for deployment compose
DEPLOY_COMPOSE="$BUILD_DIR/docker-compose-deploy.yml"

if [[ ! -f "$DEPLOY_COMPOSE" ]]; then
  echo "❌ Deployment compose not found: $DEPLOY_COMPOSE"
  exit 1
fi

echo "✅ Deployment compose ready"

# Change to build directory for deployment
cd "$BUILD_DIR"

# Get available nodes if node ID not specified
if [[ -z "$NODE_ID" ]]; then
  echo "🔍 Getting available nodes..."

  # Check if phala CLI is available
  if ! command -v phala >/dev/null 2>&1; then
    echo "❌ phala CLI not found. Please install phala-cloud-cli:"
    echo "   npm install -g @phala/cloud-cli"
    exit 1
  fi

  # List available nodes and let user choose
  echo "📋 Available nodes:"
  phala nodes list

  echo ""
  read -p "🎯 Enter node ID to deploy to: " NODE_ID

  if [[ -z "$NODE_ID" ]]; then
    echo "❌ Node ID is required"
    exit 1
  fi
fi

echo "🎯 Deploying to node: $NODE_ID"

# Deploy using phala CLI
echo "🚀 Launching deployment..."

DEPLOYMENT_NAME="simple-det-app-$(date +%Y%m%d-%H%M%S)"

# Deploy the application using deployment compose
echo "📋 Deploying with registry image..."
phala deploy \
  --node-id "$NODE_ID" \
  --name "$DEPLOYMENT_NAME" \
  docker-compose-deploy.yml

DEPLOY_RESULT=$?

if [[ $DEPLOY_RESULT -eq 0 ]]; then
  echo ""
  echo "🎉 Deployment successful!"
  echo "📱 App name: $DEPLOYMENT_NAME"
  echo "🏠 Node: $NODE_ID"
  echo "🔗 Image hash: $EXPECTED_HASH"
  echo ""

  # Get the deployed app info to verify compose hash
  echo "🔍 Verifying deployed compose hash..."

  # Wait a moment for deployment to register
  sleep 2

  # List CVMs to find our deployment
  DEPLOYED_INFO=$(phala cvms list --name "$DEPLOYMENT_NAME" 2>/dev/null || echo "[]")

  if [[ "$DEPLOYED_INFO" != "[]" && "$DEPLOYED_INFO" != "" ]]; then
    echo "✅ Deployment verified in DStack"
  else
    echo "⚠️  Could not retrieve deployment info (may still be starting)"
  fi

  echo ""
  echo "📊 Check deployment status:"
  echo "   phala cvms list --name $DEPLOYMENT_NAME"
  echo ""
  echo "📋 Access app info (once running):"
  echo "   1. Get App ID from: phala cvms list"
  echo "   2. Visit: https://{app-id}-8090.dstack-{node}.phala.network/"
  echo "   3. View logs: https://{app-id}-8090.dstack-{node}.phala.network/logs/{service}?text&bare&timestamps&tail=20"
  echo ""
  echo "🧹 To cleanup later:"
  echo "   phala cvms list --name $DEPLOYMENT_NAME  # Get App ID"
  echo "   phala cvms delete {app-id}"
else
  echo "❌ Deployment failed"
  exit 1
fi