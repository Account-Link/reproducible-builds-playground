#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 2 ]]; then
  echo "Usage: $0 <layer1_hash> <layer2_hash>"
  echo ""
  echo "Compares the contents of two layers from image-extracts/"
  echo "Run extract-and-compare.sh first to extract the images"
  echo ""
  echo "Example:"
  echo "  $0 abc123def456 def456abc123"
  exit 1
fi

LAYER1="$1"
LAYER2="$2"

# Remove sha256: prefix if present
LAYER1=${LAYER1#sha256:}
LAYER2=${LAYER2#sha256:}

EXTRACT_DIR="./image-extracts"
if [[ ! -d "$EXTRACT_DIR" ]]; then
  echo "❌ No extracted images found. Run extract-and-compare.sh first."
  exit 1
fi

WORK_DIR="./layer-comparison"
rm -rf "$WORK_DIR"
mkdir -p "$WORK_DIR/layer1" "$WORK_DIR/layer2"

echo "🔍 Comparing layer contents:"
echo "  Layer 1: $LAYER1"
echo "  Layer 2: $LAYER2"

# Find layer files in either image1 or image2 directories
LAYER1_PATH=""
LAYER2_PATH=""

for img_dir in image1 image2; do
  if [[ -f "$EXTRACT_DIR/$img_dir/blobs/sha256/$LAYER1" ]]; then
    LAYER1_PATH="$EXTRACT_DIR/$img_dir/blobs/sha256/$LAYER1"
    break
  fi
done

for img_dir in image1 image2; do
  if [[ -f "$EXTRACT_DIR/$img_dir/blobs/sha256/$LAYER2" ]]; then
    LAYER2_PATH="$EXTRACT_DIR/$img_dir/blobs/sha256/$LAYER2"
    break
  fi
done

if [[ -z "$LAYER1_PATH" ]]; then
  echo "❌ Layer 1 not found: $LAYER1"
  exit 1
fi

if [[ -z "$LAYER2_PATH" ]]; then
  echo "❌ Layer 2 not found: $LAYER2"
  exit 1
fi

# Extract the layers (they're gzipped tar files)
echo "📦 Extracting layers..."
echo "  Layer 1: $LAYER1_PATH"
echo "  Layer 2: $LAYER2_PATH"

if ! gunzip -c "$LAYER1_PATH" | tar -xf - -C "$WORK_DIR/layer1" 2>/dev/null; then
  echo "❌ Failed to extract layer1"
  exit 1
fi

if ! gunzip -c "$LAYER2_PATH" | tar -xf - -C "$WORK_DIR/layer2" 2>/dev/null; then
  echo "❌ Failed to extract layer2"
  exit 1
fi

echo ""
echo "==========================================="
echo "DIRECTORY STRUCTURE COMPARISON"
echo "==========================================="
echo "Layer 1 contents:"
find "$WORK_DIR/layer1" -type f 2>/dev/null | sort | head -20 || echo "  (no files)"
LAYER1_FILE_COUNT=$(find "$WORK_DIR/layer1" -type f 2>/dev/null | wc -l)
if [[ $LAYER1_FILE_COUNT -gt 20 ]]; then
  echo "  ... and $((LAYER1_FILE_COUNT - 20)) more files"
fi

echo ""
echo "Layer 2 contents:"
find "$WORK_DIR/layer2" -type f 2>/dev/null | sort | head -20 || echo "  (no files)"
LAYER2_FILE_COUNT=$(find "$WORK_DIR/layer2" -type f 2>/dev/null | wc -l)
if [[ $LAYER2_FILE_COUNT -gt 20 ]]; then
  echo "  ... and $((LAYER2_FILE_COUNT - 20)) more files"
fi

echo ""
echo "==========================================="
echo "FILE DIFFERENCES"
echo "==========================================="

# Compare file lists
find "$WORK_DIR/layer1" -type f 2>/dev/null | sed "s|$WORK_DIR/layer1||" | sort > /tmp/layer1-files || touch /tmp/layer1-files
find "$WORK_DIR/layer2" -type f 2>/dev/null | sed "s|$WORK_DIR/layer2||" | sort > /tmp/layer2-files || touch /tmp/layer2-files

echo "Files only in layer1:"
ONLY_LAYER1=$(comm -23 /tmp/layer1-files /tmp/layer2-files)
if [[ -n "$ONLY_LAYER1" ]]; then
  echo "$ONLY_LAYER1" | head -10
  ONLY_LAYER1_COUNT=$(echo "$ONLY_LAYER1" | wc -l)
  if [[ $ONLY_LAYER1_COUNT -gt 10 ]]; then
    echo "  ... and $((ONLY_LAYER1_COUNT - 10)) more files"
  fi
else
  echo "  (none)"
fi

echo ""
echo "Files only in layer2:"
ONLY_LAYER2=$(comm -13 /tmp/layer1-files /tmp/layer2-files)
if [[ -n "$ONLY_LAYER2" ]]; then
  echo "$ONLY_LAYER2" | head -10
  ONLY_LAYER2_COUNT=$(echo "$ONLY_LAYER2" | wc -l)
  if [[ $ONLY_LAYER2_COUNT -gt 10 ]]; then
    echo "  ... and $((ONLY_LAYER2_COUNT - 10)) more files"
  fi
else
  echo "  (none)"
fi

echo ""
echo "Common files with different content:"
comm -12 /tmp/layer1-files /tmp/layer2-files > /tmp/common-files

DIFF_COUNT=0
while IFS= read -r file; do
  if [[ -n "$file" && -f "$WORK_DIR/layer1$file" && -f "$WORK_DIR/layer2$file" ]]; then
    if ! cmp -s "$WORK_DIR/layer1$file" "$WORK_DIR/layer2$file"; then
      echo "  📄 DIFFERENT: $file"

      # Show file metadata
      STAT1=$(stat -c "%Y %s" "$WORK_DIR/layer1$file" 2>/dev/null || echo "? ?")
      STAT2=$(stat -c "%Y %s" "$WORK_DIR/layer2$file" 2>/dev/null || echo "? ?")
      MTIME1=$(echo $STAT1 | awk '{print $1}')
      SIZE1=$(echo $STAT1 | awk '{print $2}')
      MTIME2=$(echo $STAT2 | awk '{print $1}')
      SIZE2=$(echo $STAT2 | awk '{print $2}')

      echo "    Layer1: mtime=$MTIME1 ($(date -d @$MTIME1 2>/dev/null || echo "invalid")) size=$SIZE1"
      echo "    Layer2: mtime=$MTIME2 ($(date -d @$MTIME2 2>/dev/null || echo "invalid")) size=$SIZE2"

      # Show first few bytes if text file
      if file "$WORK_DIR/layer1$file" | grep -q text; then
        echo "    First few bytes differ:"
        echo "      Layer1: $(head -c 100 "$WORK_DIR/layer1$file" | tr '\n' '\\n')"
        echo "      Layer2: $(head -c 100 "$WORK_DIR/layer2$file" | tr '\n' '\\n')"
      fi

      DIFF_COUNT=$((DIFF_COUNT + 1))
      if [[ $DIFF_COUNT -ge 5 ]]; then
        echo "  ... stopping after 5 differences (use manual inspection for more)"
        break
      fi
    fi
  fi
done < /tmp/common-files

if [[ $DIFF_COUNT -eq 0 ]]; then
  echo "  (none - all common files are identical)"
fi

echo ""
echo "==========================================="
echo "SUMMARY"
echo "==========================================="
echo "📊 Layer 1: $LAYER1_FILE_COUNT files"
echo "📊 Layer 2: $LAYER2_FILE_COUNT files"
echo "📊 Files different between layers: $DIFF_COUNT"

echo ""
echo "📁 Extracted layers available at: $WORK_DIR"
echo ""
echo "For detailed file inspection:"
echo "  ls -la $WORK_DIR/layer1/"
echo "  ls -la $WORK_DIR/layer2/"