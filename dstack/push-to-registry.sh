#!/usr/bin/env bash
set -euo pipefail

# Push deterministic build to container registry for deployment
# Usage: ./scripts/push-to-registry.sh builds/simple-det-app-YYYYMMDD-hash/build-manifest.json [registry]

if [[ $# -lt 1 ]]; then
  echo "Usage: $0 <build-manifest.json> [registry]"
  echo ""
  echo "Pushes a verified deterministic build to container registry"
  echo ""
  echo "Example:"
  echo "  $0 builds/simple-det-app-20250918-nogit/build-manifest.json"
  echo "  $0 builds/simple-det-app-20250918-nogit/build-manifest.json ghcr.io/myorg"
  exit 1
fi

BUILD_MANIFEST="$1"
REGISTRY="${2:-docker.io}"  # Default to Docker Hub

if [[ ! -f "$BUILD_MANIFEST" ]]; then
  echo "❌ Build manifest not found: $BUILD_MANIFEST"
  exit 1
fi

# Extract build info
BUILD_DIR=$(dirname "$BUILD_MANIFEST")
TAG=$(jq -r '.tag' "$BUILD_MANIFEST")
IMAGE_HASH=$(jq -r '.expected_hash' "$BUILD_MANIFEST")
VERIFICATION_STATUS=$(jq -r '.verification.status' "$BUILD_MANIFEST")

echo "🚀 Pushing deterministic build to registry..."
echo "📦 Build: $TAG"
echo "🔍 Image hash: $IMAGE_HASH"
echo "✅ Verification status: $VERIFICATION_STATUS"
echo "📡 Registry: $REGISTRY"

if [[ "$VERIFICATION_STATUS" != "DETERMINISTIC" ]]; then
  echo "❌ Build is not verified as deterministic. Cannot push."
  exit 1
fi

# Check if we have the build artifacts
BUILD_TAR="$BUILD_DIR/simple-app-build1.tar"
if [[ ! -f "$BUILD_TAR" ]]; then
  echo "❌ Build artifact not found: $BUILD_TAR"
  echo "💡 Run build-deterministic.sh first"
  exit 1
fi

# Generate image name with deterministic tag
IMAGE_NAME="simple-det-app"
if [[ "$REGISTRY" != "docker.io" ]]; then
  FULL_IMAGE="${REGISTRY}/${IMAGE_NAME}:${IMAGE_HASH}"
else
  # For Docker Hub, need to include username (use 'library' as placeholder)
  echo "💡 For Docker Hub, specify your username: docker.io/username"
  echo "💡 Using 'library' as placeholder. Update as needed."
  FULL_IMAGE="library/${IMAGE_NAME}:${IMAGE_HASH}"
fi

echo "🏷️  Image: $FULL_IMAGE"

# Load the deterministic build into Docker
echo "📥 Loading deterministic build into Docker..."
docker load -i "$BUILD_TAR"

# Get the loaded image ID from the tar
LOADED_IMAGE=$(docker load -i "$BUILD_TAR" 2>&1 | grep "Loaded image" | awk '{print $3}' || echo "")
if [[ -z "$LOADED_IMAGE" ]]; then
  echo "❌ Failed to determine loaded image ID"
  exit 1
fi

echo "✅ Loaded image: $LOADED_IMAGE"

# Tag the image for registry push
echo "🏷️  Tagging image for registry..."
docker tag "$LOADED_IMAGE" "$FULL_IMAGE"

# Push to registry
echo "📤 Pushing to registry..."
docker push "$FULL_IMAGE"

if [[ $? -eq 0 ]]; then
  echo ""
  echo "🎉 Push successful!"
  echo "📦 Image: $FULL_IMAGE"
  echo "🔍 Hash: $IMAGE_HASH"
  echo ""

  # Save registry info to build directory
  cat > "$BUILD_DIR/registry-info.json" << EOF
{
  "registry": "$REGISTRY",
  "image_name": "$IMAGE_NAME",
  "full_image": "$FULL_IMAGE",
  "image_hash": "$IMAGE_HASH",
  "pushed_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
EOF

  echo "📋 Registry info saved: $BUILD_DIR/registry-info.json"
  echo ""
  echo "🚀 Ready for deployment! Use scripts/deploy-to-dstack.sh"
else
  echo "❌ Push failed"
  exit 1
fi