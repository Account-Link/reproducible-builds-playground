#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "Usage: $0 <build-manifest.json>"
  echo ""
  echo "Verifies deterministic builds using manifest reference values"
  echo ""
  echo "Example:"
  echo "  $0 builds/simple-det-app-20250918-abc123/build-manifest.json"
  exit 1
fi

MANIFEST="$1"
if [[ ! -f "$MANIFEST" ]]; then
  echo "❌ Manifest file not found: $MANIFEST"
  exit 1
fi

REQ_TOOLS=(jq docker)
for t in "${REQ_TOOLS[@]}"; do command -v "$t" >/dev/null || { echo "missing $t"; exit 1; }; done

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

echo "🔍 Verifying deterministic build using manifest: $MANIFEST"

# Parse manifest
SOURCE_DATE_EPOCH=$(jq -r '.build_parameters.source_date_epoch' "$MANIFEST")
DEBIAN_SNAPSHOT=$(jq -r '.build_parameters.debian_snapshot' "$MANIFEST")
EXPECTED_HASH=$(jq -r '.expected_hash' "$MANIFEST")

echo "📋 Build parameters:"
echo "  SOURCE_DATE_EPOCH: $SOURCE_DATE_EPOCH"
echo "  DEBIAN_SNAPSHOT: $DEBIAN_SNAPSHOT"
echo "  Expected hash: $EXPECTED_HASH"

# Create temporary build directory
TEMP_DIR=$(mktemp -d)
trap "rm -rf $TEMP_DIR" EXIT

echo "[verify] Creating temporary build environment"

# Copy app source to temp directory
cp -r simple-app/ "$TEMP_DIR/"

# Define build arguments
BUILD_ARGS="--build-arg SOURCE_DATE_EPOCH=$SOURCE_DATE_EPOCH --build-arg DEBIAN_SNAPSHOT=$DEBIAN_SNAPSHOT"

# Clear Docker build cache for clean verification
echo "[verify] Clearing Docker build cache"
docker builder prune -af >/dev/null

# Rebuild with identical parameters (no cache to catch non-determinism)
echo "[verify] Rebuilding with identical parameters (no cache)"
SOURCE_DATE_EPOCH="$SOURCE_DATE_EPOCH" docker buildx build \
  $BUILD_ARGS \
  --no-cache \
  -f "$TEMP_DIR/simple-app/Dockerfile" \
  --output type=oci,dest="$ROOT/verify-simple-app.tar",rewrite-timestamp=true \
  "$TEMP_DIR/simple-app"

# Compare hashes
ACTUAL_HASH=$(sha256sum verify-simple-app.tar | awk '{print $1}')

echo ""
echo "=========================================="
echo "VERIFICATION RESULTS"
echo "=========================================="
echo "Expected: $EXPECTED_HASH"
echo "Actual:   $ACTUAL_HASH"

if [[ "$ACTUAL_HASH" == "$EXPECTED_HASH" ]]; then
  echo "✅ VERIFIED"
  echo ""
  echo "🎉 BUILD VERIFIED DETERMINISTIC"
  echo ""
  echo "The build reproduces identical results as specified in the manifest."
  echo "This confirms the build process is deterministic and secure."

  # Clean up verification files
  rm -f verify-simple-app.tar
  exit 0
else
  echo "❌ VERIFICATION FAILED"
  echo ""
  echo "💥 VERIFICATION FAILED"
  echo ""
  echo "The build does not match the expected hash."
  echo "This indicates the build process is not deterministic or"
  echo "the build environment differs from the original."

  # Keep verification files for debugging
  echo ""
  echo "Verification file kept for debugging:"
  echo "  verify-simple-app.tar"
  exit 1
fi