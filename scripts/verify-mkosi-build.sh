#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

if [[ $# -ne 1 ]]; then
  echo "Usage: $0 <build-manifest.json>"
  exit 1
fi

MANIFEST="$1"
if [[ ! -f "$MANIFEST" ]]; then
  echo "❌ Manifest file not found: $MANIFEST"
  exit 1
fi

BUILD_DIR="$(dirname "$MANIFEST")"
EXPECTED_HASH=$(jq -r '.expected_hash' "$MANIFEST")
SOURCE_DATE_EPOCH=$(jq -r '.build_parameters.source_date_epoch' "$MANIFEST")
DEBIAN_SNAPSHOT=$(jq -r '.build_parameters.debian_snapshot' "$MANIFEST")

echo "🔍 Verifying mkosi build determinism"
echo "📋 Expected hash: $EXPECTED_HASH"
echo "📅 Source date: $(date -d "@$SOURCE_DATE_EPOCH")"
echo "📦 Debian snapshot: $DEBIAN_SNAPSHOT"
echo ""

# Update mkosi config with manifest parameters
cp mkosi.conf mkosi.conf.backup
sed -i "s|Mirror=.*|Mirror=http://snapshot.debian.org/archive/debian/${DEBIAN_SNAPSHOT}/|" mkosi.conf
sed -i "s|SourceDateEpoch=.*|SourceDateEpoch=${SOURCE_DATE_EPOCH}|" mkosi.conf

# Clean and rebuild
echo "🔨 Running verification build..."
rm -f mkosi.output.tar
mkosi clean
mkosi -f build

# Check hash
VERIFY_HASH=$(sha256sum mkosi.output.tar | awk '{print $1}')

# Restore original config
mv mkosi.conf.backup mkosi.conf

echo ""
echo "=========================================="
echo "MKOSI BUILD VERIFICATION RESULTS"
echo "=========================================="
echo "Original: $EXPECTED_HASH"
echo "Verify:   $VERIFY_HASH"
echo ""

if [[ "$EXPECTED_HASH" == "$VERIFY_HASH" ]]; then
  echo "✅ DETERMINISTIC - Hashes match!"

  # Additional forensics with systemd-dissect
  echo ""
  echo "🔍 Image forensics:"
  systemd-dissect --json=pretty mkosi.output.tar | jq -r '.name, .size, .usage'

  rm -f mkosi.output.tar
  exit 0
else
  echo "❌ NON-DETERMINISTIC - Hashes differ!"
  echo ""
  echo "🔍 Keeping verification output for analysis:"
  echo "  Original: ${BUILD_DIR}/simple-app-mkosi.tar"
  echo "  Verify:   mkosi.output.tar"
  echo ""
  echo "🛠️  Compare with:"
  echo "  systemd-dissect --json=pretty ${BUILD_DIR}/simple-app-mkosi.tar > original.json"
  echo "  systemd-dissect --json=pretty mkosi.output.tar > verify.json"
  echo "  diff original.json verify.json"

  exit 1
fi