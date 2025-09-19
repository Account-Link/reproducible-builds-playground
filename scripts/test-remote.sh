#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 2 ]]; then
  echo "Usage: $0 <remote-host> <build-manifest.json> [ssh-key]"
  echo ""
  echo "Tests deterministic build verification on a remote machine"
  echo ""
  echo "Examples:"
  echo "  $0 ubuntu@remote.example.com builds/simple-det-app-20250918-abc123/build-manifest.json"
  echo "  $0 user@10.0.1.100 builds/simple-det-app-20250918-abc123/build-manifest.json ~/.ssh/my-key"
  exit 1
fi

REMOTE_HOST="$1"
MANIFEST="$2"
SSH_KEY="${3:-}"

if [[ ! -f "$MANIFEST" ]]; then
  echo "❌ Manifest file not found: $MANIFEST"
  exit 1
fi

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

# Setup SSH command with optional key
SSH_CMD="ssh"
SCP_CMD="scp"
if [[ -n "$SSH_KEY" ]]; then
  SSH_CMD="ssh -i $SSH_KEY"
  SCP_CMD="scp -i $SSH_KEY"
fi

echo "🌐 Testing deterministic build verification on remote machine"
echo "📡 Remote host: $REMOTE_HOST"
echo "📋 Manifest: $MANIFEST"

# Test SSH connectivity
echo "🔗 Testing SSH connectivity..."
if ! $SSH_CMD "$REMOTE_HOST" "echo 'SSH connection successful'" >/dev/null 2>&1; then
  echo "❌ Cannot connect to $REMOTE_HOST"
  echo "   Make sure SSH is configured and the host is reachable"
  exit 1
fi
echo "✅ SSH connection successful"

# Check remote dependencies
echo "🔍 Checking remote dependencies..."
MISSING_DEPS=$($SSH_CMD "$REMOTE_HOST" "
  missing=()
  for cmd in docker jq git; do
    if ! command -v \$cmd >/dev/null 2>&1; then
      missing+=(\$cmd)
    fi
  done
  echo \${missing[*]}
")

if [[ -n "$MISSING_DEPS" ]]; then
  echo "❌ Missing dependencies on remote host: $MISSING_DEPS"
  echo "   Install required tools: sudo apt-get update && sudo apt-get install -y docker.io jq git"
  exit 1
fi
echo "✅ Remote dependencies satisfied"

# Setup remote workspace
REMOTE_DIR="/tmp/det-build-test-$(date +%s)"
echo "📁 Setting up remote workspace: $REMOTE_DIR"

$SSH_CMD "$REMOTE_HOST" "
  mkdir -p $REMOTE_DIR/{simple-app,scripts} &&
  echo 'Remote workspace created'
"

# Copy files to remote
echo "📤 Copying files to remote machine..."
$SCP_CMD simple-app/* "$REMOTE_HOST:$REMOTE_DIR/simple-app/"
$SCP_CMD scripts/verify-build.sh "$REMOTE_HOST:$REMOTE_DIR/scripts/"
$SCP_CMD "$MANIFEST" "$REMOTE_HOST:$REMOTE_DIR/"

# Make scripts executable
$SSH_CMD "$REMOTE_HOST" "chmod +x $REMOTE_DIR/scripts/*.sh"

# Check Docker access
echo "🐳 Checking Docker access..."
DOCKER_STATUS=$($SSH_CMD "$REMOTE_HOST" "
  if docker info >/dev/null 2>&1; then
    echo 'ok'
  elif sudo docker info >/dev/null 2>&1; then
    echo 'sudo'
  else
    echo 'fail'
  fi
")

case "$DOCKER_STATUS" in
  "ok")
    DOCKER_CMD="docker"
    ;;
  "sudo")
    DOCKER_CMD="sudo docker"
    echo "ℹ️  Using sudo for Docker commands"
    ;;
  "fail")
    echo "❌ Docker not accessible on remote host"
    echo "   Make sure Docker is installed and user has access"
    exit 1
    ;;
esac

# Setup Docker buildx if needed
echo "🔧 Setting up Docker buildx..."
$SSH_CMD "$REMOTE_HOST" "
  if ! $DOCKER_CMD buildx ls | grep -q 'docker-container'; then
    $DOCKER_CMD buildx create --name det-builder --driver docker-container --use || true
    $DOCKER_CMD buildx inspect --bootstrap || true
  fi
"

# Run verification on remote
echo "🧪 Running deterministic build verification on remote..."
MANIFEST_NAME=$(basename "$MANIFEST")

VERIFICATION_RESULT=$($SSH_CMD "$REMOTE_HOST" "
  cd $REMOTE_DIR
  export DOCKER_BUILDKIT=1
  if scripts/verify-build.sh $MANIFEST_NAME; then
    echo 'SUCCESS'
  else
    echo 'FAILED'
  fi
" 2>&1)

echo "📊 Remote verification output:"
echo "$VERIFICATION_RESULT"

# Copy verification file for analysis before cleanup
echo "📥 Copying verification file for analysis..."
if $SSH_CMD "$REMOTE_HOST" "test -f $REMOTE_DIR/verify-simple-app.tar"; then
  $SCP_CMD "$REMOTE_HOST:$REMOTE_DIR/verify-simple-app.tar" ./remote-verify-simple-app.tar
  echo "✅ Remote verification file copied to: remote-verify-simple-app.tar"
fi

# Cleanup remote workspace
echo "🧹 Cleaning up remote workspace..."
$SSH_CMD "$REMOTE_HOST" "rm -rf $REMOTE_DIR"

# Final result
if echo "$VERIFICATION_RESULT" | grep -q "SUCCESS"; then
  echo ""
  echo "🎉 REMOTE VERIFICATION SUCCESS"
  echo ""
  echo "The deterministic build was successfully verified on the remote machine."
  echo "This proves the build process is truly deterministic across different environments."
  exit 0
else
  echo ""
  echo "💥 REMOTE VERIFICATION FAILED"
  echo ""
  echo "The build verification failed on the remote machine."
  echo "This could indicate environment differences or non-deterministic build steps."
  exit 1
fi
