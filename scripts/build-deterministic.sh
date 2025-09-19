#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

REQ_TOOLS=(jq docker curl)
for t in "${REQ_TOOLS[@]}"; do command -v "$t" >/dev/null || { echo "missing $t"; exit 1; }; done

DATESTAMP=$(date +"%Y%m%d")
GIT_HASH=$(git rev-parse --short HEAD 2>/dev/null || echo "nogit")
TAG="${DATESTAMP}-${GIT_HASH}"
OUTPUT_DIR="$ROOT/builds/simple-det-app-${TAG}"

echo "🏗️  Building deterministic simple app: ${TAG}"
echo "📁 Output directory: $OUTPUT_DIR"

rm -rf "$OUTPUT_DIR"
mkdir -p "$OUTPUT_DIR"

# Copy app source and compose files
cp -r simple-app/ "$OUTPUT_DIR/"
cp docker-compose.yml "$OUTPUT_DIR/"

# Resolve build parameters
BASE_IMG=$(grep -m1 -E '^FROM ' simple-app/Dockerfile | awk '{print $2}')
CREATED=$(docker image inspect "$BASE_IMG" --format '{{.Created}}')
SEED="${SNAPSHOT_DATE:-$(date -u -d "$CREATED + 3 days" +%Y%m%dT%H%M%SZ)}"

echo "📅 Base image: $BASE_IMG (created: $CREATED)"
echo "📅 Snapshot seed: $SEED"

# Find working Debian snapshot
SNAPSHOT_DATE=$(scripts/simple-probe-snapshot.sh "$SEED" | awk -F= '/SNAPSHOT_DATE/{print $2}')
[[ -n "${SNAPSHOT_DATE:-}" ]] || { echo "❌ Could not determine SNAPSHOT_DATE"; exit 1; }

# Calculate SOURCE_DATE_EPOCH
if git rev-parse --git-dir >/dev/null 2>&1; then
  git_ts=$(git log -1 --pretty=%ct 2>/dev/null || echo "0")
else
  git_ts=0
fi
base_ts=$(date -u -d "$CREATED" +%s)
SOURCE_DATE_EPOCH=$((git_ts > base_ts ? git_ts : base_ts))

echo "✅ DEBIAN_SNAPSHOT=$SNAPSHOT_DATE"
echo "✅ SOURCE_DATE_EPOCH=$SOURCE_DATE_EPOCH ($(date -d @$SOURCE_DATE_EPOCH))"

# Apply resolved values to compose file
COMPOSE_FILE="$OUTPUT_DIR/docker-compose.yml"
sed -i "s/SOURCE_DATE_EPOCH: \"\"/SOURCE_DATE_EPOCH: \"$SOURCE_DATE_EPOCH\"/" "$COMPOSE_FILE"
sed -i "s/DEBIAN_SNAPSHOT: \"\"/DEBIAN_SNAPSHOT: \"$SNAPSHOT_DATE\"/" "$COMPOSE_FILE"

BUILD_ARGS="--build-arg SOURCE_DATE_EPOCH=$SOURCE_DATE_EPOCH --build-arg DEBIAN_SNAPSHOT=$SNAPSHOT_DATE"

# Build twice for determinism verification
echo "🔨 Building image (build 1)"
docker builder prune -af >/dev/null
SOURCE_DATE_EPOCH="$SOURCE_DATE_EPOCH" docker buildx build \
  $BUILD_ARGS \
  -f "$OUTPUT_DIR/simple-app/Dockerfile" \
  --output type=oci,dest="$OUTPUT_DIR/simple-app-build1.tar",rewrite-timestamp=true \
  "$OUTPUT_DIR/simple-app"

HASH1=$(sha256sum "$OUTPUT_DIR/simple-app-build1.tar" | awk '{print $1}')

echo "🔨 Building image (build 2)"
docker builder prune -af >/dev/null
SOURCE_DATE_EPOCH="$SOURCE_DATE_EPOCH" docker buildx build \
  $BUILD_ARGS \
  -f "$OUTPUT_DIR/simple-app/Dockerfile" \
  --output type=oci,dest="$OUTPUT_DIR/simple-app-build2.tar",rewrite-timestamp=true \
  "$OUTPUT_DIR/simple-app"

HASH2=$(sha256sum "$OUTPUT_DIR/simple-app-build2.tar" | awk '{print $1}')

# Verify determinism
echo ""
echo "=========================================="
echo "DETERMINISTIC BUILD VERIFICATION"
echo "=========================================="
echo "Build 1: $HASH1"
echo "Build 2: $HASH2"

if [[ "$HASH1" == "$HASH2" ]]; then
  echo "✅ DETERMINISTIC"
  STATUS="DETERMINISTIC"
else
  echo "❌ NON-DETERMINISTIC"
  STATUS="NON-DETERMINISTIC"
fi

# Generate deployment compose and app-compose hash (only if deterministic)
if [[ "$STATUS" == "DETERMINISTIC" ]]; then
  echo ""
  echo "🏗️  Generating deployment artifacts..."

  # Create deployment compose by replacing build section with image reference
  DEPLOY_COMPOSE="$OUTPUT_DIR/docker-compose-deploy.yml"
  PLACEHOLDER_IMAGE="simple-det-app:$HASH1"

  # Generate deployment compose by replacing build section with image reference
  cat "$OUTPUT_DIR/docker-compose.yml" | \
  sed '/build:/,/DEBIAN_SNAPSHOT:/d' | \
  sed "s/simple-det-app:/&\n    image: $PLACEHOLDER_IMAGE/" > "$DEPLOY_COMPOSE"

  echo "📄 Generated deployment compose with placeholder image"

  # Note: App-compose hash is generated server-side by DStack during deployment
  # The salt is randomly generated, so we cannot predict the hash locally
  echo "📄 Deployment compose ready for DStack (hash will be computed server-side)"
fi

# Generate build manifest
cat > "$OUTPUT_DIR/build-manifest.json" << EOF
{
  "tag": "${TAG}",
  "timestamp": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "git_commit": "$(if git rev-parse --verify HEAD >/dev/null 2>&1; then git rev-parse HEAD; else echo "no-commits"; fi)",
  "build_parameters": {
    "source_date_epoch": "$SOURCE_DATE_EPOCH",
    "debian_snapshot": "$SNAPSHOT_DATE",
    "base_image": "$BASE_IMG"
  },
  "expected_hash": "$HASH1",
  "verification": {
    "status": "$STATUS"
  },
  "dstack_info": {
    "app_compose_file": "app-compose-generated.json",
    "docker_compose_file": "docker-compose.yml",
    "note": "app-compose hash computed server-side by DStack during deployment"
  }
}
EOF

echo ""
if [[ "$STATUS" == "DETERMINISTIC" ]]; then
  echo "🎉 DETERMINISTIC BUILD SUCCESS"
  echo "📦 Image hash: $HASH1"
  echo "📋 Manifest: $OUTPUT_DIR/build-manifest.json"
  echo ""
  echo "📁 Generated files:"
  echo "  📄 $OUTPUT_DIR/docker-compose.yml - Build compose with deterministic args"
  echo "  📄 $OUTPUT_DIR/docker-compose-deploy.yml - Deployment compose with image references"
  echo "  📄 $OUTPUT_DIR/app-compose-generated.json - DStack app-compose configuration (template)"
  echo "  📋 $OUTPUT_DIR/build-manifest.json - Complete build metadata"
  echo ""
  echo "🔍 To verify independently:"
  echo "  scripts/verify-build.sh $OUTPUT_DIR/build-manifest.json"
  echo ""
  echo "🚀 For DStack deployment:"
  echo "  Use: dstack/deploy-to-dstack.sh $OUTPUT_DIR/build-manifest.json"
  echo "  Note: App-compose hash will be computed server-side during deployment"
else
  echo "💥 DETERMINISTIC BUILD FAILED"
  exit 1
fi