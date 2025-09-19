#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

VENDOR_DIR="$ROOT/vendor"
APT_DIR="$VENDOR_DIR/apt"
NPM_DIR="$VENDOR_DIR/npm"

echo "🏗️  Vendoring all build dependencies for offline builds"

# Get snapshot date from build system or use default probe
if [[ -n "${SNAPSHOT_DATE:-}" ]]; then
  echo "📅 Using provided Debian snapshot: $SNAPSHOT_DATE"
else
  # Use the same logic as build-deterministic.sh to get consistent snapshot
  BASE_IMAGE_CREATED=$(docker inspect node:18-slim@sha256:f9ab18e354e6855ae56ef2b290dd225c1e51a564f87584b9bd21dd651838830e --format '{{.Created}}' 2>/dev/null | head -1)
  if [[ -n "$BASE_IMAGE_CREATED" ]]; then
    SEED_DATE=$(date -d "$BASE_IMAGE_CREATED" +%Y%m%dT%H%M%SZ 2>/dev/null || echo "20250330T142308Z")
  else
    SEED_DATE="20250330T142308Z"
  fi

  SNAPSHOT_DATE=$(scripts/smart-probe-snapshot.sh "$SEED_DATE" | awk -F= '/SNAPSHOT_DATE/{print $2}')
  echo "📅 Auto-detected Debian snapshot: $SNAPSHOT_DATE (seed: $SEED_DATE)"
fi

# Create vendor directories
mkdir -p "$APT_DIR" "$NPM_DIR"

# Vendor APT packages
echo "📦 Vendoring APT packages..."
TEMP_CONTAINER=$(docker run -d --rm \
  -e DEBIAN_SNAPSHOT="$SNAPSHOT_DATE" \
  debian:bookworm-slim sleep 3600)

# Set up snapshot sources in container
docker exec "$TEMP_CONTAINER" bash -c "
  echo 'deb http://snapshot.debian.org/archive/debian/${SNAPSHOT_DATE} bookworm main' > /etc/apt/sources.list &&
  echo 'deb http://snapshot.debian.org/archive/debian/${SNAPSHOT_DATE} bookworm-updates main' >> /etc/apt/sources.list &&
  echo 'deb http://snapshot.debian.org/archive/debian-security/${SNAPSHOT_DATE} bookworm-security main' >> /etc/apt/sources.list &&
  apt-get -o Acquire::Check-Valid-Until=false update
"

# Download curl package and dependencies
docker exec "$TEMP_CONTAINER" bash -c "
  mkdir -p /tmp/apt-cache/partial &&
  apt-get -y --no-install-recommends --download-only \
    -o Dir::Cache::archives=/tmp/apt-cache \
    install curl=7.88.1-10+deb12u14
"

# Copy APT packages out of container
docker cp "$TEMP_CONTAINER:/tmp/apt-cache" "$VENDOR_DIR/apt-temp"
mv "$VENDOR_DIR/apt-temp"/*.deb "$APT_DIR/" 2>/dev/null || true
rm -rf "$VENDOR_DIR/apt-temp"

# Create simple APT repo index
(cd "$APT_DIR"
  if command -v apt-ftparchive >/dev/null 2>&1; then
    apt-ftparchive packages . > Packages
    gzip -f -k Packages
    echo "Created APT repo index"
  else
    echo "Warning: apt-ftparchive not available, skipping repo index"
  fi
)

# Cleanup container
docker stop "$TEMP_CONTAINER"

echo "✅ APT packages vendored: $(ls "$APT_DIR"/*.deb | wc -l) packages"

# Vendor npm packages
echo "📦 Vendoring npm packages..."
if [[ -f "simple-app/package-lock.json" ]]; then
  # Extract all package URLs from lockfile
  jq -r '
    .packages | to_entries[] |
    select(.value.resolved? and .value.integrity?) |
    [.value.name // (.key|split("node_modules/")[-1]), .value.version, .value.resolved] |
    @tsv
  ' simple-app/package-lock.json | sort -u | while IFS=$'\t' read -r name ver url; do
    if [[ -n "$name" && -n "$ver" && -n "$url" ]]; then
      # Sanitize filename
      safe_name=$(echo "$name" | tr '/' '_' | tr '@' '_')
      file="$NPM_DIR/${safe_name}-${ver}.tgz"

      if [[ ! -f "$file" ]]; then
        echo "  Downloading $name@$ver..."
        if curl -fsSL "$url" -o "$file"; then
          echo "    ✅ $file"
        else
          echo "    ❌ Failed to download $name@$ver"
        fi
      else
        echo "    ⏭️  Already have $file"
      fi
    fi
  done

  # Create npm manifest
  jq -r '
    .packages | to_entries[] |
    select(.value.resolved? and .value.integrity?) |
    {
      name: (.value.name // (.key|split("node_modules/")[-1])),
      version: .value.version,
      integrity: .value.integrity,
      url: .value.resolved
    }
  ' simple-app/package-lock.json | jq -s . > "$NPM_DIR/manifest.json"

  echo "✅ npm packages vendored: $(ls "$NPM_DIR"/*.tgz 2>/dev/null | wc -l) packages"
else
  echo "❌ No package-lock.json found in simple-app/"
fi

# Create vendor manifest
cat > "$VENDOR_DIR/vendor-manifest.json" << EOF
{
  "created": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "debian_snapshot": "$SNAPSHOT_DATE",
  "apt_packages": $(find "$APT_DIR" -name "*.deb" | wc -l),
  "npm_packages": $(find "$NPM_DIR" -name "*.tgz" 2>/dev/null | wc -l)
}
EOF

echo ""
echo "🎉 Vendoring complete!"
echo "📁 Vendor directory: $VENDOR_DIR"
echo "📋 Manifest: $VENDOR_DIR/vendor-manifest.json"
echo ""
echo "💾 Total size: $(du -sh "$VENDOR_DIR" | cut -f1)"
echo ""
echo "🔄 To test offline build:"
echo "  OFFLINE=1 ./scripts/build-deterministic.sh"