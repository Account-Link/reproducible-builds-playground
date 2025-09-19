#!/usr/bin/env bash
set -euo pipefail

# Simple but fast snapshot finder - just use known good dates

BASE_IMG='node:18-slim@sha256:f9ab18e354e6855ae56ef2b290dd225c1e51a564f87584b9bd21dd651838830e'

# Get base image creation time
CREATED=$(docker image inspect "$BASE_IMG" --format '{{.Created}}')
START_DATE="${1:-$(date -u -d "$CREATED + 7 days" +%Y%m%dT000000Z)}"

echo "🔍 Simple snapshot search starting from: $START_DATE" >&2

# Known good snapshots for common Debian 12 packages
# These are pre-tested and work
KNOWN_GOOD_DATES=(
  "20240901T000000Z"
)

# Find the first date >= START_DATE
START_EPOCH=$(date -u -d "${START_DATE:0:4}-${START_DATE:4:2}-${START_DATE:6:2}" +%s)

for candidate in "${KNOWN_GOOD_DATES[@]}"; do
  candidate_epoch=$(date -u -d "${candidate:0:4}-${candidate:4:2}-${candidate:6:2}" +%s)

  if [[ $candidate_epoch -ge $START_EPOCH ]]; then
    echo "✅ Using known good snapshot: $candidate" >&2
    echo "SNAPSHOT_DATE=$candidate"
    exit 0
  fi
done

echo "❌ No known good snapshot found after $START_DATE" >&2
exit 1
