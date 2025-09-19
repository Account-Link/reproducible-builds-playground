#!/usr/bin/env bash
set -euo pipefail

# Push deterministic build to container registry for deployment
# Supports both Docker and Nix builds
# Usage: ./dstack/push-to-registry.sh builds/simple-det-app-YYYYMMDD-hash/build-manifest.json [registry]

if [[ $# -lt 1 ]]; then
  echo "Usage: $0 <build-manifest.json> [registry]"
  echo ""
  echo "Pushes a verified deterministic build to container registry"
  echo "Supports both Docker and Nix builds"
  echo ""
  echo "Example:"
  echo "  $0 builds/simple-det-app-20250918-nogit/build-manifest.json"
  echo "  $0 builds/simple-det-app-nix-20250919-abc123/build-manifest.json"
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
BUILD_TYPE=$(jq -r '.build_type // "docker"' "$BUILD_MANIFEST")
IMAGE_HASH=$(jq -r '.expected_hash' "$BUILD_MANIFEST")

echo "🚀 Pushing deterministic build to registry..."
echo "🏗️  Build type: $BUILD_TYPE"
echo "🔍 Image hash: $IMAGE_HASH"
echo "📡 Registry: $REGISTRY"

# Determine source image based on build type
if [[ "$BUILD_TYPE" == "nix" ]]; then
  # For Nix builds, get the image reference from manifest
  IMAGE_REF=$(jq -r '.image_reference' "$BUILD_MANIFEST")
  SOURCE_IMAGE="$IMAGE_REF"
  echo "🔍 Nix image ref: $IMAGE_REF"
else
  # For Docker builds, check for build artifacts
  BUILD_TAR="$BUILD_DIR/simple-app-build1.tar"
  if [[ ! -f "$BUILD_TAR" ]]; then
    echo "❌ Build artifact not found: $BUILD_TAR"
    echo "💡 Run build-deterministic.sh first"
    exit 1
  fi
  SOURCE_IMAGE="simple-det-app:$IMAGE_HASH"
fi

# Generate registry image name with hash tag
IMAGE_NAME="simple-det-app"
if [[ "$REGISTRY" == docker.io/* ]]; then
  # Docker Hub format: docker.io/username/image:tag
  FULL_IMAGE="${REGISTRY}/${IMAGE_NAME}:${IMAGE_HASH}"
elif [[ "$REGISTRY" != "docker.io" ]]; then
  FULL_IMAGE="${REGISTRY}/${IMAGE_NAME}:${IMAGE_HASH}"
else
  # For Docker Hub, need to include username (use 'library' as placeholder)
  echo "💡 For Docker Hub, specify your username: docker.io/username"
  echo "💡 Using 'library' as placeholder. Update as needed."
  FULL_IMAGE="library/${IMAGE_NAME}:${IMAGE_HASH}"
fi

echo "🏷️  Target image: $FULL_IMAGE"

# Check if the source image exists
if ! docker image inspect "$SOURCE_IMAGE" >/dev/null 2>&1; then
  echo "❌ Source image not found: $SOURCE_IMAGE"
  if [[ "$BUILD_TYPE" == "nix" ]]; then
    echo "💡 Run build-deterministic-nix.sh first"
  else
    echo "💡 Run build-deterministic.sh first"
  fi
  exit 1
fi

echo "✅ Found source image: $SOURCE_IMAGE"

# Tag the image for registry push
echo "🏷️  Tagging image for registry..."
docker tag "$SOURCE_IMAGE" "$FULL_IMAGE"

# Push to registry
echo "📤 Pushing to registry..."
docker push "$FULL_IMAGE"

if [[ $? -eq 0 ]]; then
  echo ""
  echo "🎉 Push successful!"
  echo "📦 Image: $FULL_IMAGE"
  echo "🔍 Hash: $IMAGE_HASH"
  echo "🏗️  Build: $BUILD_TYPE"
  echo ""

  # Update deployment compose to use registry image
  DEPLOY_COMPOSE="$BUILD_DIR/docker-compose-deploy.yml"
  echo "📋 Updating deployment compose to use registry image..."

  cat > "$DEPLOY_COMPOSE" << EOF
services:
  simple-det-app:
    image: $FULL_IMAGE
    ports:
      - "3000:3000"
    restart: "no"
EOF

  echo "✅ Updated: $DEPLOY_COMPOSE"

  # Save registry info to build directory
  cat > "$BUILD_DIR/registry-info.json" << EOF
{
  "registry": "$REGISTRY",
  "image_name": "$IMAGE_NAME",
  "full_image": "$FULL_IMAGE",
  "local_image": "$SOURCE_IMAGE",
  "image_hash": "$IMAGE_HASH",
  "build_type": "$BUILD_TYPE",
  "pushed_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
EOF

  echo "📋 Registry info saved: $BUILD_DIR/registry-info.json"
  echo ""
  echo "🚀 Ready for DStack deployment!"
  echo "💡 Use: ./dstack/deploy-to-dstack.sh $BUILD_MANIFEST"
else
  echo "❌ Push failed"
  exit 1
fi