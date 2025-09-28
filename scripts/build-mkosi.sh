#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

REQ_TOOLS=(mkosi podman sha256sum)
for t in "${REQ_TOOLS[@]}"; do command -v "$t" >/dev/null || { echo "missing $t"; exit 1; }; done

DATESTAMP=$(date +"%Y%m%d")
GIT_HASH=$(git rev-parse --short HEAD 2>/dev/null || echo "nogit")
TAG="${DATESTAMP}-${GIT_HASH}"
OUTPUT_DIR="$ROOT/builds/simple-mkosi-app-${TAG}"

echo "🏗️  Building mkosi deterministic app: ${TAG}"
echo "📁 Output directory: $OUTPUT_DIR"

rm -rf "$OUTPUT_DIR"
mkdir -p "$OUTPUT_DIR"

# Build with mkosi in Docker container (has root)
echo "🔨 Building OS image with mkosi in Docker"
docker build -f mkosi/Dockerfile.mkosi -t mkosi-builder .
docker run --privileged --rm \
  -v "$PWD:/work/output" \
  -w /work \
  mkosi-builder /bin/bash -c "
    . venv/bin/activate &&
    mkosi -f build &&
    cp mkosi.output.tar.zst /work/output/mkosi.output.tar.zst 2>/dev/null ||
    cp mkosi.output.tar /work/output/mkosi.output.tar 2>/dev/null ||
    true
  "

# Find the output file (could be .tar or .tar.zst)
if [[ -f "mkosi.output.tar.zst" ]]; then
  OUTPUT_FILE="mkosi.output.tar.zst"
elif [[ -f "mkosi.output.tar" ]]; then
  OUTPUT_FILE="mkosi.output.tar"
else
  echo "❌ No mkosi output file found"
  exit 1
fi

# Get hash of the output
HASH1=$(sha256sum "$OUTPUT_FILE" | awk '{print $1}')
mv "$OUTPUT_FILE" "$OUTPUT_DIR/simple-app-mkosi.tar"

# Convert to OCI image for DStack compatibility
echo "🔄 Converting to OCI image for DStack compatibility"
podman import "$OUTPUT_DIR/simple-app-mkosi.tar" "simple-mkosi-app:$HASH1"

# Export OCI image
podman save "simple-mkosi-app:$HASH1" -o "$OUTPUT_DIR/simple-app-oci.tar"
OCI_HASH=$(sha256sum "$OUTPUT_DIR/simple-app-oci.tar" | awk '{print $1}')

# Generate build manifest
cat > "$OUTPUT_DIR/build-manifest.json" << EOF
{
  "build_parameters": {
    "source_date_epoch": "1701475200",
    "debian_snapshot": "20241201T000000Z",
    "mkosi_format": "tar"
  },
  "expected_hash": "$HASH1",
  "oci_hash": "$OCI_HASH"
}
EOF

echo ""
echo "✅ mkosi build complete!"
echo "📦 OS image hash: $HASH1"
echo "📦 OCI image hash: $OCI_HASH"
echo "📋 Manifest: $OUTPUT_DIR/build-manifest.json"
echo ""
echo "🔍 To verify:"
echo "  systemd-dissect --json=pretty $OUTPUT_DIR/simple-app-mkosi.tar"