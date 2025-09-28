#!/usr/bin/env bash
set -euo pipefail

# Push mkosi-built deterministic image to container registry for DStack deployment
# Usage: ./scripts/push-mkosi-to-registry.sh builds/simple-mkosi-app-YYYYMMDD-hash/build-manifest.json [registry]

if [[ $# -lt 1 ]]; then
  echo "Usage: $0 <build-manifest.json> [registry]"
  echo ""
  echo "Pushes a verified mkosi deterministic build to container registry"
  echo ""
  echo "Example:"
  echo "  $0 builds/simple-mkosi-app-20250927-602336f/build-manifest.json"
  echo "  $0 builds/simple-mkosi-app-20250927-602336f/build-manifest.json docker.io/username"
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
IMAGE_HASH=$(jq -r '.expected_hash' "$BUILD_MANIFEST")

echo "🚀 Pushing mkosi deterministic build to registry..."
echo "🔍 Image hash: $IMAGE_HASH"
echo "📡 Registry: $REGISTRY"

# Check if we have the mkosi build artifacts
MKOSI_TAR="$BUILD_DIR/simple-app-mkosi.tar"
if [[ ! -f "$MKOSI_TAR" ]]; then
  echo "❌ mkosi build artifact not found: $MKOSI_TAR"
  echo "💡 Run scripts/build-mkosi.sh first"
  exit 1
fi

echo "✅ Found mkosi tar: $MKOSI_TAR"

# Import mkosi tar as Docker image
SOURCE_IMAGE="simple-mkosi-app:$IMAGE_HASH"

echo "📦 Importing mkosi tar to Docker..."
if docker image inspect "$SOURCE_IMAGE" >/dev/null 2>&1; then
  echo "✅ Image already imported: $SOURCE_IMAGE"
else
  # Check if tar is compressed
  if file "$MKOSI_TAR" | grep -q "Zstandard"; then
    echo "🗜️  Decompressing zstd tar..."
    TEMP_TAR="${MKOSI_TAR%.tar}-uncompressed.tar"
    zstd -d "$MKOSI_TAR" -o "$TEMP_TAR" --force
    docker import "$TEMP_TAR" "$SOURCE_IMAGE"
    rm -f "$TEMP_TAR"
  else
    docker import "$MKOSI_TAR" "$SOURCE_IMAGE"
  fi
  echo "✅ Imported: $SOURCE_IMAGE"
fi

# Generate image name with deterministic tag
IMAGE_NAME="simple-mkosi-app"
if [[ "$REGISTRY" == "docker.io" ]]; then
  # For Docker Hub, must include username
  if [[ "$REGISTRY" == "docker.io" && "$2" != *"/"* ]]; then
    echo "❌ For Docker Hub, specify your username: docker.io/username"
    echo "💡 Example: docker.io/myusername"
    exit 1
  fi
  FULL_IMAGE="${REGISTRY}/${IMAGE_NAME}:${IMAGE_HASH}"
elif [[ "$REGISTRY" != *"/"* ]]; then
  # Assume username format for Docker Hub
  FULL_IMAGE="${REGISTRY}/${IMAGE_NAME}:${IMAGE_HASH}"
else
  # Full registry path provided
  FULL_IMAGE="${REGISTRY}/${IMAGE_NAME}:${IMAGE_HASH}"
fi

echo "🏷️  Image: $FULL_IMAGE"

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
  echo ""

  # Save registry info to build directory
  cat > "$BUILD_DIR/registry-info.json" << EOF
{
  "registry": "$REGISTRY",
  "image_name": "$IMAGE_NAME",
  "full_image": "$FULL_IMAGE",
  "image_hash": "$IMAGE_HASH",
  "image_type": "mkosi",
  "source_tar": "$(basename "$MKOSI_TAR")",
  "pushed_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
EOF

  echo "📋 Registry info saved: $BUILD_DIR/registry-info.json"

  # Generate Docker compose for DStack deployment
  echo "🐳 Generating Docker compose for DStack..."

  cat > "$BUILD_DIR/docker-compose-deploy.yml" << EOF
services:
  simple-mkosi-app:
    image: "$FULL_IMAGE"
    ports:
      - "3000:3000"
    restart: "no"
    working_dir: /opt/app
    command: ["/usr/bin/node", "/opt/app/server.js"]
EOF

  echo "📋 Docker compose saved: $BUILD_DIR/docker-compose-deploy.yml"

  # Generate docker-compose.yml for DStack deployment
  cat > "$BUILD_DIR/docker-compose.yml" << EOF
services:
  simple-mkosi-app:
    image: $FULL_IMAGE
    ports:
      - "3000:3000"
    restart: "no"
    working_dir: /opt/app
    command: ["/usr/bin/node", "/opt/app/server.js"]
EOF

  echo "📋 DStack docker-compose saved: $BUILD_DIR/docker-compose.yml"

  echo ""
  echo "🚀 Ready for deployment! Use:"
  echo "   ./dstack/deploy-to-dstack.sh $BUILD_MANIFEST"
else
  echo "❌ Push failed"
  exit 1
fi