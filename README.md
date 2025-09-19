# Deterministic Build Practice

A simplified environment for learning and practicing deterministic Docker builds.

## Overview

This practice folder contains a minimal Node.js app with both npm dependencies (express) and apt packages (curl) to demonstrate deterministic build techniques. It's based on the patterns from the main audit-tools but simplified for learning.

## Quick Start

### 1. Build Deterministically
```bash
./scripts/build-deterministic.sh
```

This will:
- Create a timestamped build in `builds/`
- Generate deterministic docker-compose configurations
- Build the container once and verify with `--no-cache` rebuild
- Verify both builds produce identical hashes
- Generate a minimal build manifest for verification

### 2. Verify a Build
```bash
./scripts/verify-build.sh builds/simple-det-app-YYYYMMDD-hash/build-manifest.json
```

This rebuilds the container with identical parameters using `--no-cache` and confirms it matches the expected hash.

### 3. Test on Remote Machine
```bash
./scripts/test-remote.sh user@remote-host builds/simple-det-app-YYYYMMDD-hash/build-manifest.json
```

This copies the verification script to a remote machine and runs it there to prove the build is deterministic across different environments.

## What Makes Builds Deterministic

### Critical Components

The following steps are ESSENTIAL for achieving reproducible builds. Remove any of these and builds will become non-deterministic:

1. **Pinned Base Images**: Uses SHA256 digest instead of tags
   ```dockerfile
   FROM node:18-slim@sha256:f9ab18e354e6855ae56ef2b290dd225c1e51a564f87584b9bd21dd651838830e
   ```

2. **Fixed Debian Snapshots**: All apt packages from specific point-in-time
   ```dockerfile
   RUN echo "deb [check-valid-until=no] http://snapshot.debian.org/archive/debian/${DEBIAN_SNAPSHOT} bookworm main" > /etc/apt/sources.list
   ```

3. **Exact Package Versions**: No version ranges anywhere
   ```dockerfile
   apt-get install -y --no-install-recommends curl=7.88.1-10+deb12u14
   ```

4. **Comprehensive apt Cleanup**: Remove all cache and log files
   ```dockerfile
   rm -rf /var/lib/apt/lists/* && \
   rm -rf /var/cache/ldconfig/aux-cache && \
   rm -rf /var/log/apt/* && \
   rm -rf /var/log/dpkg.log
   ```

5. **npm Cache Cleanup**: Remove npm cache completely
   ```dockerfile
   RUN mkdir -p /npm-cache && \
       npm ci --omit=dev --ignore-scripts --prefer-offline && \
       rm -rf /npm-cache
   ```

6. **Timestamp Normalization**: Apply SOURCE_DATE_EPOCH to all files
   ```dockerfile
   find /app -exec touch -d "@${SOURCE_DATE_EPOCH}" {} +
   ```

7. **BuildKit with rewrite-timestamp**: Essential for layer determinism
   ```bash
   docker buildx build --output type=image,name=myapp,rewrite-timestamp=true
   ```

### Files

**Application:**
- `simple-app/Dockerfile` - Demonstrates proper deterministic Dockerfile patterns
- `simple-app/package.json` - Shows exact version pinning
- `simple-app/server.js` - Simple Express app that uses curl

**Compose Configuration:**
- `docker-compose.yml` - Unified compose file with build args for deterministic builds

**Deterministic Build Scripts:**
- `scripts/build-deterministic.sh` - Core build script with verification
- `scripts/verify-build.sh` - Independent verification script
- `scripts/smart-probe-snapshot.sh` - Intelligently finds working Debian snapshot dates and package versions
- `scripts/test-remote.sh` - Tests verification on remote machines

**Differential Analysis Tools:**
- `diff-tools/extract-and-compare.sh` - Extract OCI layers for comparison
- `diff-tools/compare-layer-contents.sh` - Compare layer contents file-by-file

**DStack Integration:**
- `dstack/get-compose-hash.py` - Generates DStack-compatible compose hashes
- `dstack/get-deployed-salt.sh` - Extracts salt from deployed DStack instances
- `dstack/verify-deployment.sh` - Complete deployment verification workflow
- `dstack/deploy-to-dstack.sh` - Prepares DStack deployment packages
- `dstack/push-to-registry.sh` - Registry push utilities
- `dstack/verify-deployed-hash.py` - Verifies deployed app-compose matches local build

## Requirements

- Docker with BuildKit enabled
- `jq` for JSON processing
- SSH access to remote machines (for remote testing)
- Phala Cloud CLI and authentication (for DStack deployment)

### Docker BuildKit Setup

```bash
# Create buildx builder
docker buildx create --name mybuilder --driver docker-container --use
docker buildx inspect --bootstrap
```

### Phala Cloud CLI Setup

```bash
# Install Phala Cloud CLI
npm install -g @phala/cloud-cli

# Authenticate
phala auth login
```

## Experimental Playground

This environment is designed for experimentation. Try breaking determinism to understand what each component does:

### 🧪 Recommended Experiments

1. **Remove apt cleanup** - Comment out the comprehensive apt cleanup in `simple-app/Dockerfile`:
   ```bash
   # Comment out: rm -rf /var/cache/ldconfig/aux-cache && rm -rf /var/log/apt/* && rm -rf /var/log/dpkg.log
   ./scripts/build-deterministic.sh  # Will fail determinism check
   ./diff-tools/extract-and-compare.sh builds/*/simple-app-build1.tar verify-simple-app.tar
   ```

2. **Remove npm cache cleanup** - Comment out `rm -rf /npm-cache` in `simple-app/Dockerfile`:
   ```bash
   # Comment out: rm -rf /npm-cache
   ./scripts/build-deterministic.sh  # Will fail determinism check with --no-cache verification
   ```

   **Note**: The build script uses `--no-cache` during verification to catch non-determinism that Docker layer caching would otherwise hide. This ensures the verification step rebuilds from scratch and detects issues like leftover npm cache files.

3. **Skip timestamp normalization** - Remove the `find /app -exec touch` command:
   ```bash
   # Build will be non-deterministic due to file timestamps
   ```

4. **Use version ranges** - Change package.json to use `"express": "^4.18.0"` instead of exact version:
   ```bash
   # Different npm resolution may occur
   ```

5. **Remove rewrite-timestamp** - Use regular docker build instead of buildx:
   ```bash
   docker build -t test-no-rewrite .  # Layer timestamps will vary
   ```

### 🎯 How Verification Catches Non-Determinism

The build system uses a two-phase approach to detect non-deterministic builds:

1. **Initial build**: Creates the image with normal Docker caching for efficiency
2. **Verification with `--no-cache`**: Rebuilds from scratch to catch non-determinism that caching would hide

This approach is critical because:
- **Same-machine builds** often appear deterministic due to Docker layer caching
- **`--no-cache` verification** forces fresh package downloads and rebuilds, exposing issues like:
  - Leftover npm cache files
  - Inconsistent apt package states
  - Timestamp variations
  - Network-dependent package resolution

**Example**: Commenting out `rm -rf /npm-cache` will:
- ✅ Pass on cached builds (appears deterministic)
- ❌ Fail on `--no-cache` verification (reveals true non-determinism)

### 🔍 Analysis Workflow

When experiments fail determinism:

1. **Extract verification builds**: `./diff-tools/extract-and-compare.sh builds/*/simple-app-build1.tar verify-simple-app.tar`
2. **Compare layer contents**: `./diff-tools/compare-layer-contents.sh /tmp/build1 /tmp/verify`
3. **Examine specific differences**: Look at the diff output to understand exactly what files changed
4. **Fix and verify**: Re-add the missing component and confirm determinism returns

### 📊 Understanding Output

- `extract-and-compare.sh` shows which layers differ between builds
- `compare-layer-contents.sh` shows file-level differences within layers
- Use these tools to trace exactly which files are causing non-determinism

## Troubleshooting

### Common Issues

- **Build not deterministic**: Check for version ranges, missing --ignore-scripts, or timestamp issues
- **Snapshot not found**: The smart probe automatically finds valid dates and updates package versions
- **Remote verification fails**: Ensure Docker buildx and dependencies are installed

### Debug Commands

```bash
# Compare two image tars manually
tar -tf builds/*/simple-app-build1.tar | sort > build1.files
tar -tf verify-simple-app.tar | sort > verify.files
diff build1.files verify.files

# Check package versions in built image
docker run --rm your-image dpkg -l
docker run --rm your-image npm list --depth=0
```

## DStack Deployment

### App Compose Hash

The app compose hash is a critical component for verifying deterministic builds in DStack. It ensures that the configuration used to deploy your application matches exactly what you tested during development.

**How it works:**
1. **Local Build**: Creates deterministic Docker images and deployment configurations
2. **DStack Deployment**: DStack converts your `docker-compose.yml` to app-compose format and generates a random salt server-side
3. **Post-Deployment Verification**: Extract the deployed salt and verify our local compose generates the same hash

**Key insight:** The salt is generated randomly by DStack during deployment, so we cannot predict the final hash during the build phase.

#### Corrected Workflow: Post-Deployment Verification

**Step 1: Build deterministically**
```bash
./scripts/build-deterministic.sh
# Creates: docker images, docker-compose-deploy.yml, build manifest
# Note: No app-compose hash generated (salt is unknown until deployment)
```

**Step 2: Deploy to DStack**
```bash
cd builds/simple-det-app-*/
phala deploy -c docker-compose-deploy.yml -n simple-det-app-verification
# DStack generates random salt and computes final app-compose hash server-side
```

**Step 3: Verify deployment matches local build**
```bash
# Wait 2-3 minutes for deployment to complete, then:
dstack/verify-deployment.sh app_YOUR_APP_ID builds/simple-det-app-*/build-manifest.json
# Output: ✅ HASH MATCH - Our compose generates same hash as deployed!

# Or extract just the salt for manual verification:
dstack/get-deployed-salt.sh app_YOUR_APP_ID
# Output: 6ed9e7827a294556a01d27d5d36004e2
```

**What this verification proves:**
- Your local docker-compose content matches deployed version exactly
- No configuration drift between development and production
- DStack deployment process is deterministic (modulo the random salt)

### Deployment Instructions

#### 1. Prepare Build for Deployment
```bash
# Build deterministically with verification
./scripts/build-deterministic.sh

# This creates a timestamped build directory with:
# - build-manifest.json (minimal verification parameters)
# - simple-app-build1.tar (OCI image archive)
# - docker-compose-deploy.yml (deployment configuration)
```

#### 2. Deploy to DStack
```bash
# Push to registry using automated script
./dstack/push-to-registry.sh builds/simple-det-app-YYYYMMDD-hash/build-manifest.json docker.io/socrates1024

# Deploy using the build manifest
./dstack/deploy-to-dstack.sh builds/simple-det-app-YYYYMMDD-hash/build-manifest.json

# Or manually using phala CLI:
cd builds/simple-det-app-YYYYMMDD-hash/
phala deploy -f docker-compose-deploy.yml --app-name simple-det-app-verification
```

#### 3. Verify Deployment
After deployment, use our verification script:
```bash
# Extract deployed salt and verify hash matches local generation
dstack/verify-deployment.sh app_YOUR_APP_ID builds/simple-det-app-YYYYMMDD-hash/build-manifest.json
```

**This verification ensures:**
- No configuration drift between development and production
- Exact docker-compose content is deployed
- Security settings and environment variables match exactly
- Pre-launch scripts are identical

#### 4. Troubleshooting Deployment

**Hash Mismatch Issues:**
```bash
# Check your image hash from manifest
jq -r '.expected_hash' builds/*/build-manifest.json

# Verify the pushed image matches
docker images | grep simple-det-app

# Compare with deployed configuration
phala cvms list
```

**Common deployment issues:**
- Docker image not pushed to accessible registry
- Invalid docker-compose syntax for DStack
- Missing Phala Cloud authentication
- Network connectivity to DStack nodes

### DStack Configuration Format

The app-compose format includes DStack-specific metadata:

```json
{
    "allowed_envs": [],
    "default_gateway_domain": null,
    "docker_compose_file": "...",
    "features": ["kms", "tproxy-net"],
    "gateway_enabled": true,
    "kms_enabled": true,
    "local_key_provider_enabled": false,
    "manifest_version": 2,
    "name": "simple-det-app-verification",
    "no_instance_id": false,
    "pre_launch_script": "...",
    "public_logs": true,
    "public_sysinfo": true,
    "runner": "docker-compose",
    "salt": "05fcefaecd984204bb6ccf16938eaad5",
    "tproxy_enabled": true
}
```
