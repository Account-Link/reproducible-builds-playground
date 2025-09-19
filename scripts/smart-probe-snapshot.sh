#!/usr/bin/env bash
set -euo pipefail

# Smart snapshot prober - finds working package versions and updates Dockerfile
# Usage: ./smart-probe-snapshot.sh [start_date]

BASE_IMG='node:18-slim@sha256:f9ab18e354e6855ae56ef2b290dd225c1e51a564f87584b9bd21dd651838830e'
CREATED=$(docker image inspect "$BASE_IMG" --format '{{.Created}}')
START_DATE="${1:-$(date -u -d "$CREATED + 3 days" +%Y%m%dT000000Z)}"

echo "🔍 Smart snapshot probe starting from: $START_DATE" >&2

# Function to test a snapshot date and find available package versions
test_snapshot_and_find_versions() {
  local snapshot_date="$1"

  echo "🧪 Testing $snapshot_date..." >&2

  # Test with a minimal container to see what's available
  local test_result=$(docker run --rm --quiet debian:bookworm-slim bash -c "
    echo 'deb [check-valid-until=no] http://snapshot.debian.org/archive/debian/${snapshot_date} bookworm main' > /etc/apt/sources.list
    echo 'deb [check-valid-until=no] http://snapshot.debian.org/archive/debian/${snapshot_date} bookworm-updates main' >> /etc/apt/sources.list
    echo 'deb [check-valid-until=no] http://snapshot.debian.org/archive/debian-security/${snapshot_date} bookworm-security main' >> /etc/apt/sources.list

    if apt-get -o Acquire::Check-Valid-Until=false update >/dev/null 2>&1; then
      # Find the latest available curl version
      curl_version=\$(apt-cache policy curl 2>/dev/null | grep 'Candidate:' | awk '{print \$2}' | head -1)
      if [[ -n \"\$curl_version\" && \"\$curl_version\" != \"(none)\" ]]; then
        echo \"curl=\$curl_version\"
        exit 0
      fi
    fi
    exit 1
  " 2>/dev/null)

  if [[ $? -eq 0 && -n "$test_result" ]]; then
    echo "   ✅ Found working curl version: $test_result" >&2
    echo "$snapshot_date:$test_result"
    return 0
  else
    echo "   ❌ No working curl version found" >&2
    return 1
  fi
}

# Convert start date to epoch for iteration
START_EPOCH=$(date -u -d "${START_DATE:0:4}-${START_DATE:4:2}-${START_DATE:6:2}" +%s)

echo "🔄 Searching for working snapshot with available packages..." >&2

# Try recent past dates first (more likely to have the packages we need)
for days_offset in $(seq -30 7 90); do  # Start 30 days ago, test every 7 days up to 90 days ahead
  test_epoch=$((START_EPOCH + days_offset * 86400))
  test_date=$(date -u -d "@$test_epoch" +%Y%m%dT000000Z)

  if result=$(test_snapshot_and_find_versions "$test_date"); then
    snapshot_date="${result%%:*}"
    package_version="${result##*:}"

    echo "✅ Found working snapshot: $snapshot_date with $package_version" >&2

    # Update the Dockerfile with the working version
    if [[ -f "simple-app/Dockerfile" ]]; then
      echo "🔧 Updating Dockerfile with working package version..." >&2
      sed -i "s/curl=[^[:space:]]*/curl=${package_version##*=}/g" simple-app/Dockerfile
      echo "   Updated: curl=${package_version##*=}" >&2
    fi

    echo "SNAPSHOT_DATE=$snapshot_date"
    exit 0
  fi
done

echo "❌ No working snapshot found" >&2
echo "💡 The base image might be too new, or package dependencies have changed" >&2
exit 1