#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 2 ]]; then
  echo "Usage: $0 <image1.tar> <image2.tar>"
  echo ""
  echo "Extracts and compares two OCI image tars to find differences"
  echo ""
  echo "Example:"
  echo "  $0 simple-app-build1.tar simple-app-build2.tar"
  exit 1
fi

IMG1="$1"
IMG2="$2"

if [[ ! -f "$IMG1" ]]; then
  echo "❌ Image 1 not found: $IMG1"
  exit 1
fi

if [[ ! -f "$IMG2" ]]; then
  echo "❌ Image 2 not found: $IMG2"
  exit 1
fi

# Create persistent extraction directory
EXTRACT_DIR="./image-extracts"
rm -rf "$EXTRACT_DIR"
mkdir -p "$EXTRACT_DIR/image1" "$EXTRACT_DIR/image2"

echo "🔍 Extracting images to $EXTRACT_DIR"
echo "📦 Image 1: $IMG1"
echo "📦 Image 2: $IMG2"

tar -xf "$IMG1" -C "$EXTRACT_DIR/image1"
tar -xf "$IMG2" -C "$EXTRACT_DIR/image2"

# Get manifest hashes
IMG1_MANIFEST=$(jq -r '.manifests[0].digest' "$EXTRACT_DIR/image1/index.json" | cut -d: -f2)
IMG2_MANIFEST=$(jq -r '.manifests[0].digest' "$EXTRACT_DIR/image2/index.json" | cut -d: -f2)

echo ""
echo "==========================================="
echo "IMAGE MANIFEST COMPARISON"
echo "==========================================="
echo "Image 1 manifest: $IMG1_MANIFEST"
echo "Image 2 manifest: $IMG2_MANIFEST"

if [[ "$IMG1_MANIFEST" == "$IMG2_MANIFEST" ]]; then
  echo "✅ Manifests are identical"
  exit 0
else
  echo "❌ Manifests differ - analyzing layers"
fi

# Extract layer lists
echo ""
echo "=== LAYER COMPARISON ==="
echo "Image 1 layers:"
jq -r '.layers[].digest' "$EXTRACT_DIR/image1/blobs/sha256/$IMG1_MANIFEST" | nl
echo ""
echo "Image 2 layers:"
jq -r '.layers[].digest' "$EXTRACT_DIR/image2/blobs/sha256/$IMG2_MANIFEST" | nl

# Find different layers
echo ""
echo "=== LAYER DIFFERENCES ==="
jq -r '.layers[].digest' "$EXTRACT_DIR/image1/blobs/sha256/$IMG1_MANIFEST" | sort > /tmp/img1-layers
jq -r '.layers[].digest' "$EXTRACT_DIR/image2/blobs/sha256/$IMG2_MANIFEST" | sort > /tmp/img2-layers

echo "Layers only in image1:"
comm -23 /tmp/img1-layers /tmp/img2-layers || echo "  (none)"
echo ""
echo "Layers only in image2:"
comm -13 /tmp/img1-layers /tmp/img2-layers || echo "  (none)"
echo ""
COMMON_COUNT=$(comm -12 /tmp/img1-layers /tmp/img2-layers | wc -l)
echo "Common layers: $COMMON_COUNT"

# Show different layers for analysis
echo ""
echo "=== DIFFERENT LAYERS TO INVESTIGATE ==="
DIFF_LAYERS_1=$(comm -23 /tmp/img1-layers /tmp/img2-layers)
DIFF_LAYERS_2=$(comm -13 /tmp/img1-layers /tmp/img2-layers)

if [[ -n "$DIFF_LAYERS_1" ]]; then
  echo "🔍 Layers unique to image1:"
  echo "$DIFF_LAYERS_1" | while read -r layer; do
    echo "  $layer"
  done
fi

if [[ -n "$DIFF_LAYERS_2" ]]; then
  echo "🔍 Layers unique to image2:"
  echo "$DIFF_LAYERS_2" | while read -r layer; do
    echo "  $layer"
  done
fi

echo ""
echo "==========================================="
echo "NEXT STEPS"
echo "==========================================="
echo "To investigate layer contents, use:"
echo ""

if [[ -n "$DIFF_LAYERS_1" ]]; then
  FIRST_DIFF=$(echo "$DIFF_LAYERS_1" | head -1 | cut -d: -f2)
  echo "  scripts/compare-layer-contents.sh $FIRST_DIFF <corresponding_layer_from_image2>"
fi

if [[ -n "$DIFF_LAYERS_2" ]]; then
  FIRST_DIFF=$(echo "$DIFF_LAYERS_2" | head -1 | cut -d: -f2)
  echo "  scripts/compare-layer-contents.sh <corresponding_layer_from_image1> $FIRST_DIFF"
fi

echo ""
echo "📁 Extracted images available at: $EXTRACT_DIR"