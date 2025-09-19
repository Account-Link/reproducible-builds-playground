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
- Generate deterministic docker-compose and app-compose configurations
- Calculate DStack-compatible compose hash
- Build the container twice with identical parameters
- Verify both builds produce identical hashes
- Generate a complete build manifest for verification

### 2. Verify a Build
```bash
./scripts/verify-build.sh builds/simple-det-app-YYYYMMDD-hash/build-manifest.json
```

This rebuilds the container with identical parameters and confirms it matches the expected hash.

### 3. Test on Remote Machine
```bash
./scripts/test-remote.sh user@remote-host builds/simple-det-app-YYYYMMDD-hash/build-manifest.json
```

This copies the verification script to a remote machine and runs it there to prove the build is deterministic across different environments.

### 4. Deploy to DStack
```bash
./dstack/deploy-to-dstack.sh builds/simple-det-app-YYYYMMDD-hash/build-manifest.json
```

This prepares a DStack deployment package with the verified deterministic build and compose hash.

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
- `scripts/simple-probe-snapshot.sh` - Finds working Debian snapshot dates
- `scripts/test-remote.sh` - Tests verification on remote machines

**Differential Analysis Tools:**
- `diff-tools/extract-and-compare.sh` - Extract OCI layers for comparison
- `diff-tools/compare-layer-contents.sh` - Compare layer contents file-by-file

**DStack Integration:**
- `dstack/get-compose-hash.py` - Generates DStack-compatible compose hashes
- `dstack/deploy-to-dstack.sh` - Prepares DStack deployment packages
- `dstack/push-to-registry.sh` - Registry push utilities
- `dstack/verify-deployed-hash.py` - Verifies deployed app-compose matches local build

## Requirements

- Docker with BuildKit enabled
- `jq` for JSON processing
- Python 3 with `pyyaml` for compose hash generation
- SSH access to remote machines (for remote testing)

### Docker BuildKit Setup

```bash
# Create buildx builder
docker buildx create --name mybuilder --driver docker-container --use
docker buildx inspect --bootstrap
```

## Experimental Playground

This environment is designed for experimentation. Try breaking determinism to understand what each component does:

### 🧪 Recommended Experiments

1. **Remove apt cleanup** - Comment out the comprehensive apt cleanup in `simple-app/Dockerfile`:
   ```bash
   # Comment out: rm -rf /var/cache/ldconfig/aux-cache && rm -rf /var/log/apt/* && rm -rf /var/log/dpkg.log
   ./scripts/build-deterministic.sh  # Will fail determinism check
   ./scripts/extract-and-compare.sh builds/*/build1.tar builds/*/build2.tar
   ```

2. **Remove npm cache cleanup** - Comment out `rm -rf /npm-cache`:
   ```bash
   # Comment out: rm -rf /npm-cache
   ./scripts/build-deterministic.sh  # Will fail determinism check
   ./scripts/compare-layer-contents.sh /tmp/build1 /tmp/build2  # See npm cache differences
   ```

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

### 🔍 Analysis Workflow

When experiments fail determinism:

1. **Extract both builds**: `./diff-tools/extract-and-compare.sh build1.tar build2.tar`
2. **Compare layer contents**: `./diff-tools/compare-layer-contents.sh /tmp/build1 /tmp/build2`
3. **Examine specific differences**: Look at the diff output to understand exactly what files changed
4. **Fix and verify**: Re-add the missing component and confirm determinism returns

### 📊 Understanding Output

- `extract-and-compare.sh` shows which layers differ between builds
- `compare-layer-contents.sh` shows file-level differences within layers
- Use these tools to trace exactly which files are causing non-determinism

## Troubleshooting

### Common Issues

- **Build not deterministic**: Check for version ranges, missing --ignore-scripts, or timestamp issues
- **Snapshot not found**: Use probe-snapshot.sh to find valid dates
- **Remote verification fails**: Ensure Docker buildx and dependencies are installed

### Debug Commands

```bash
# Compare two image tars manually
tar -tf build1.tar | sort > build1.files
tar -tf build2.tar | sort > build2.files
diff build1.files build2.files

# Check package versions in built image
docker run --rm your-image dpkg -l
docker run --rm your-image npm list --depth=0
```

## DStack Deployment

### App Compose Hash

The app compose hash is a critical component for verifying deterministic builds in DStack. It ensures that the configuration used to deploy your application matches exactly what you tested during development.

**How it works:**
1. **App Compose Generation**: Your `docker-compose.yml` is converted to DStack's app-compose format using `dstack/get-compose-hash.py`
2. **Hash Calculation**: A SHA256 hash is calculated from the complete app-compose JSON (including pre-launch scripts, security settings, and compose content)
3. **Verification**: The hash must match between your local build and the deployed instance (using the deployed salt)

#### Quick Reference: Finding Your Compose Hash

**After running `./scripts/build-deterministic.sh`:**
```bash
# The compose hash is in the build output directory:
cat builds/simple-det-app-*/compose-hash.txt

# Or generate it manually from any deployment compose:
python3 dstack/get-compose-hash.py builds/simple-det-app-*/docker-compose-deploy.yml
```

**During deployment verification:**
```bash
# 1. Deploy your application:
cd builds/simple-det-app-*/
phala deploy -c docker-compose-deploy.yml -n simple-det-app-verification

# 2. Download deployed app-compose (wait 2-3 minutes after deployment):
phala cvms get YOUR_APP_ID --json | tail -n +4 > deployed-app-compose.json

# 3. Verify hash matches using deployed salt:
python3 ../../dstack/verify-deployed-hash.py docker-compose-deploy.yml deployed-app-compose.json
# Output: ✅ HASH MATCH - Our compose generates same hash as deployed!
```

**Files created by the hash generation:**
- `compose-hash.txt` - **THE HASH** you need for verification
- `app-compose-generated.json` - DStack-formatted configuration
- `app-compose-deterministic.json` - Compact format for reference

### Deployment Instructions

#### 1. Prepare Build for Deployment
```bash
# Build deterministically with verification
./scripts/build-deterministic.sh

# This creates a timestamped build directory with:
# - build-manifest.json (build metadata)
# - docker images (build1.tar, build2.tar)
# - app-compose configurations
# - compose hash verification
```

#### 2. Deploy to DStack
```bash
# Deploy using the build manifest
./scripts/deploy-to-dstack.sh builds/simple-det-app-YYYYMMDD-hash/build-manifest.json

# Or manually using phala CLI:
cd builds/simple-det-app-YYYYMMDD-hash/
phala deploy -f docker-compose-deploy.yml --app-name simple-det-app-verification
```

#### 3. Verify Deployment
After deployment, DStack will:
1. Generate its own app-compose hash from your uploaded configuration
2. Compare it against your locally calculated hash
3. Ensure the deployed configuration exactly matches your tested build

**Hash verification ensures:**
- No configuration drift between development and production
- Exact docker-compose content is deployed
- Security settings and environment variables match exactly
- Pre-launch scripts are identical

#### 4. Troubleshooting Deployment

**Hash Mismatch Issues:**
```bash
# Check your generated hash
cat builds/*/compose-hash.txt

# Regenerate if needed
python3 scripts/get-compose-hash.py docker-compose-deploy.yml

# Compare with downloaded app-compose from DStack
diff app-compose-generated.json downloaded-app-compose.json
```

**Common deployment issues:**
- App compose hash mismatch (most common)
- Docker image not pushed to accessible registry
- Invalid docker-compose syntax for DStack
- Missing required DStack fields (name, features, etc.)

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

Key fields:
- `docker_compose_file`: Your complete docker-compose.yml content
- `features`: DStack features required (KMS, network proxy)
- `pre_launch_script`: Standardized startup script for credentials and cleanup
- `salt`: Fixed value for deterministic hash calculation

## Related Documentation

See the main `audit-tools/README.md` for the full production system that inspired this practice environment.