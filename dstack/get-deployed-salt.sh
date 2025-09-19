#!/usr/bin/env bash
set -euo pipefail

# Extract the deployed salt from a running DStack instance
# Usage: ./scripts/get-deployed-salt.sh <app_id>

if [[ $# -lt 1 ]]; then
  echo "Usage: $0 <app_id>"
  echo ""
  echo "Extracts the deployed salt from a running DStack instance"
  echo ""
  echo "Examples:"
  echo "  $0 app_b8312d741acb5650237e70d84148eea4de0cfaae"
  echo "  $0 b8312d741acb5650237e70d84148eea4de0cfaae"
  exit 1
fi

APP_ID="$1"

# Strip app_ prefix if present
APP_ID_CLEAN="${APP_ID#app_}"

echo "🔍 Extracting deployed salt for app: $APP_ID_CLEAN" >&2

# Step 1: Get the Node Info URL from phala CLI
echo "🌐 Finding Node Info URL..." >&2
NODE_URL=$(phala cvms ls | grep -A 10 -B 2 "$APP_ID_CLEAN" | grep "Node Info URL" | sed 's/.*│ //' | sed 's/ │.*//' | head -1)

if [[ -z "$NODE_URL" ]]; then
  echo "❌ Could not find Node Info URL for app: $APP_ID" >&2
  echo "💡 Available apps:" >&2
  phala cvms ls | grep "App ID" >&2
  exit 1
fi

echo "✅ Found Node Info URL: $NODE_URL" >&2

# Step 2: Fetch and extract the salt
echo "🧂 Extracting salt from deployed instance..." >&2
DEPLOYED_SALT=$(curl -s "$NODE_URL" | grep -o '\\&#34;salt\\&#34;:\\&#34;[^\\]*\\&#34;' | sed 's/.*:\\&#34;//' | sed 's/\\&#34;.*//')

if [[ -z "$DEPLOYED_SALT" ]]; then
  echo "❌ Could not extract salt from deployed instance" >&2
  echo "💡 Make sure the app is running and accessible" >&2
  echo "💡 Node URL: $NODE_URL" >&2
  exit 1
fi

echo "✅ Successfully extracted salt: $DEPLOYED_SALT" >&2

# Output just the salt (for use in other scripts)
echo "$DEPLOYED_SALT"