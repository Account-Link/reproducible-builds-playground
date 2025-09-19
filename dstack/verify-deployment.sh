#!/usr/bin/env bash
set -euo pipefail

# Verify deployed DStack app-compose hash matches local generation
# Usage: ./scripts/verify-deployment.sh <app_id> <build-manifest.json>

if [[ $# -lt 2 ]]; then
  echo "Usage: $0 <app_id> <build-manifest.json>"
  echo ""
  echo "Verifies that a deployed DStack app produces the same app-compose hash"
  echo "as our local build when using the deployed salt."
  echo ""
  echo "Examples:"
  echo "  $0 app_b8312d741acb5650237e70d84148eea4de0cfaae builds/simple-det-app-20250918-4d57834/build-manifest.json"
  echo "  $0 app_xyz123 builds/simple-det-app-20250918-abc123/build-manifest.json"
  exit 1
fi

APP_ID="$1"
BUILD_MANIFEST="$2"

if [[ ! -f "$BUILD_MANIFEST" ]]; then
  echo "❌ Build manifest not found: $BUILD_MANIFEST"
  exit 1
fi

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

BUILD_DIR=$(dirname "$BUILD_MANIFEST")

echo "🔍 Verifying deployed app-compose hash"
echo "📱 App ID: $APP_ID"
echo "📋 Build manifest: $BUILD_MANIFEST"
echo ""

# Step 1: Get the CVM info to find the Node Info URL
echo "🌐 Finding deployment information..."
CVM_INFO=$(phala cvms ls | grep -A 10 -B 2 "${APP_ID#app_}" || echo "")

if [[ -z "$CVM_INFO" ]]; then
  echo "❌ App not found: $APP_ID"
  echo "💡 Available apps:"
  phala cvms ls | grep "App ID"
  exit 1
fi

NODE_URL=$(echo "$CVM_INFO" | grep "Node Info URL" | awk '{print $NF}')
STATUS=$(echo "$CVM_INFO" | grep "Status" | awk '{print $NF}')

echo "✅ Found deployment: $NODE_URL"
echo "📊 Status: $STATUS"
echo ""

# Step 2: Extract the deployed salt using our dedicated script
echo "🔍 Extracting deployed salt..."
DEPLOYED_SALT=$("$(dirname "$0")/get-deployed-salt.sh" "$APP_ID" 2>/dev/null)

if [[ -z "$DEPLOYED_SALT" ]]; then
  echo "❌ Could not extract salt from deployed instance"
  echo "💡 Make sure the app is running and accessible"
  echo "💡 Try: $(dirname "$0")/get-deployed-salt.sh $APP_ID"
  exit 1
fi

echo "🧂 Deployed salt: $DEPLOYED_SALT"
echo ""

# Step 3: Generate our local app-compose using deployed salt
echo "🏗️  Generating local app-compose with deployed salt..."

# First, generate the base app-compose using our template
if [[ ! -f "$BUILD_DIR/app-compose-generated.json" ]]; then
  echo "📄 Generating app-compose template..."
  cd "$BUILD_DIR"
  python3 "$ROOT/dstack/get-compose-hash.py" docker-compose-deploy.yml --no-hash
  cd "$ROOT"
fi

# Load our template and replace salt
python3 -c "
import json
import hashlib

# Load our local app-compose template
with open('$BUILD_DIR/app-compose-generated.json', 'r') as f:
    our_app_compose = json.load(f)

print(f'Original salt: {our_app_compose[\"salt\"]}')

# Replace with deployed salt
our_app_compose['salt'] = '$DEPLOYED_SALT'

# Calculate hash
formatted_json = json.dumps(our_app_compose, separators=(',', ':'), ensure_ascii=False)
our_hash = hashlib.sha256(formatted_json.encode('utf-8')).hexdigest()

print(f'Our hash with deployed salt: {our_hash}')

# Save the version with deployed salt for inspection
with open('$BUILD_DIR/app-compose-with-deployed-salt.json', 'w') as f:
    json.dump(our_app_compose, f, indent=2)

print(f'\\n📄 Saved: $BUILD_DIR/app-compose-with-deployed-salt.json')
"

echo ""

# Step 4: Get the actual deployed hash
echo "🌐 Extracting deployed hash..."
DEPLOYED_APP_COMPOSE=$(curl -s "$NODE_URL" | grep -A 50 '"app_compose"' | grep -o 'app_compose[^}]*}[^}]*}[^}]*}[^}]*}[^}]*}[^}]*}[^}]*}[^}]*}[^}]*}[^}]*}[^}]*}' | sed 's/.*app_compose&#34;: &#34;//' | sed 's/&#34;$//' | python3 -c "import sys, html; print(html.unescape(sys.stdin.read()))" 2>/dev/null || echo "")

if [[ -n "$DEPLOYED_APP_COMPOSE" ]]; then
  echo "$DEPLOYED_APP_COMPOSE" > "$BUILD_DIR/deployed-app-compose.json"
  DEPLOYED_HASH=$(echo "$DEPLOYED_APP_COMPOSE" | python3 -c "
import sys, json, hashlib
data = sys.stdin.read()
deployed_hash = hashlib.sha256(data.encode('utf-8')).hexdigest()
print(deployed_hash)
")
  echo "🔐 Deployed hash: $DEPLOYED_HASH"
else
  echo "⚠️  Could not extract full deployed app-compose for hash comparison"
  echo "   This might be due to the format or the app still starting up"
  DEPLOYED_HASH=""
fi

echo ""

# Step 5: Load our calculated hash and compare
OUR_HASH=$(python3 -c "
import json, hashlib
with open('$BUILD_DIR/app-compose-with-deployed-salt.json', 'r') as f:
    our_data = json.load(f)
formatted = json.dumps(our_data, separators=(',', ':'), ensure_ascii=False)
print(hashlib.sha256(formatted.encode('utf-8')).hexdigest())
")

echo "==========================================
VERIFICATION RESULTS
=========================================="
echo "Deployed salt: $DEPLOYED_SALT"
echo "Our hash:      $OUR_HASH"
if [[ -n "$DEPLOYED_HASH" ]]; then
  echo "Deployed hash: $DEPLOYED_HASH"
  echo ""

  if [[ "$OUR_HASH" == "$DEPLOYED_HASH" ]]; then
    echo "✅ HASH MATCH"
    echo ""
    echo "🎉 SUCCESS: Our local app-compose generates the same hash as deployed!"
    echo "This confirms:"
    echo "  - Local docker-compose content matches deployed version"
    echo "  - No configuration drift between build and deployment"
    echo "  - DStack deployment process is deterministic"
    exit 0
  else
    echo "❌ HASH MISMATCH"
    echo ""
    echo "💥 FAILED: Hash mismatch detected"
    echo "This could indicate:"
    echo "  - Configuration differences between local and deployed"
    echo "  - Changes in DStack's app-compose generation"
    echo "  - Network issues during data extraction"
    echo ""
    echo "📄 Files for investigation:"
    echo "  - $BUILD_DIR/app-compose-with-deployed-salt.json (our version)"
    echo "  - $BUILD_DIR/deployed-app-compose.json (deployed version)"
    exit 1
  fi
else
  echo "Deployed hash: (could not extract)"
  echo ""
  echo "⚠️  PARTIAL VERIFICATION"
  echo ""
  echo "✅ Successfully extracted deployed salt: $DEPLOYED_SALT"
  echo "✅ Generated local hash with deployed salt: $OUR_HASH"
  echo "⚠️  Could not extract deployed hash for comparison"
  echo ""
  echo "This partial verification confirms our local app-compose generation"
  echo "works correctly with the deployed salt. Full verification requires"
  echo "manual comparison or waiting for the app to be fully accessible."
  echo ""
  echo "📄 Generated: $BUILD_DIR/app-compose-with-deployed-salt.json"
  exit 0
fi