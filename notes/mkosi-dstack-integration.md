# mkosi + DStack Integration - Implementation Notes

**Date:** 2025-09-27
**Status:** 🔧 DEBUGGING - DStack deployment partially working, JSON escaping issue identified

## What We Built and Tested

### ✅ Complete mkosi Build System
- **Working deterministic OS image builds** using mkosi v25.3
- **Manual npm dependency extraction** from vendored packages (bypassed npm PATH issues)
- **Final working image hash**: `75d2b9a8612f8f5ee08163b30cd8c9c3f8708c1026da621d0636bd98899db5e6`
- **Image specs**: 100MB compressed, 394MB uncompressed
- **Contains**: Node.js v18.20.4, Express.js dependencies, systemd service

### ✅ Registry Integration
- **Docker Hub push successful**: `docker.io/socrates1024/simple-mkosi-app:75d2b9a8612f8f5ee08163b30cd8c9c3f8708c1026da621d0636bd98899db5e6`
- **Local testing confirmed working**:
  ```bash
  curl http://localhost:3004/
  # Returns: {"message":"Deterministic build practice app","timestamp":"2025-09-28T01:56:12.264Z","nodeVersion":"v18.20.4"}

  curl http://localhost:3004/health
  # Returns: {"status":"healthy","curl":"curl 7.88.1..."}
  ```

### ✅ DStack Deployment Infrastructure
- **Created scripts**:
  - `scripts/push-mkosi-to-registry.sh` - Registry push + file generation
  - `scripts/deploy-mkosi-to-dstack.sh` - Deployment wrapper
- **Generated deployment files**:
  - `docker-compose-deploy.yml` - Docker compose format
  - `app-compose-generated.json` - DStack format
  - `registry-info.json` - Registry metadata

### 🔧 Current Issue: JSON Escaping Bug

**DStack deployment created successfully** but failing at runtime:
- **CVM ID**: `80b9e332-5b8e-48df-8720-07ad4dce37dd`
- **App ID**: `339a623059d499495122d466a3de39a025e4c546`
- **Dashboard**: https://cloud.phala.network/dashboard/cvms/80b9e332-5b8e-48df-8720-07ad4dce37dd

**Error in DStack logs**:
```
Error: Failed to parse docker-compose.yaml
Scan error at position Line: 4, Column: 198, Index: 256
```

**Root cause identified with evidence**:
- JSON contains malformed escape sequences: `\\"3000:3000\\"` at position ~256
- `jq` command also fails to parse the JSON: `parse error: Expected separator between values at line 4, column 203`
- The issue is **double-escaping quotes** when generating `app-compose-generated.json`

## Key Technical Learnings

### 1. mkosi npm Dependency Handling
**Problem**: npm not available in mkosi chroot build environment
**Solution**: Manual extraction of vendored `.tgz` packages
```bash
# In mkosi.build script:
EXPRESS_TGZ=$(find "$SRCDIR/vendor/npm" -name "express-*.tgz" | head -1)
cd node_modules && tar -xzf "$EXPRESS_TGZ"
# Extract all other dependencies similarly
```

### 2. DStack Deployment Methods
**Discovery**: Two deployment approaches
- ❌ `docker-compose.yml` - Tries to build, looks for Dockerfile
- ✅ `app-compose.json` - Uses pre-built registry images
- **Command**: `phala deploy --node-id 16 --kms-id phala-prod8 --name "app-name" app-compose.json`

### 3. Registry Image Format Requirements
- DStack pre-launch script handles Docker Hub authentication
- Public registry images work correctly
- Long image names need proper JSON escaping

### 4. JSON Generation Bug Pattern
**Current buggy code** in `push-mkosi-to-registry.sh`:
```bash
cat > "$BUILD_DIR/app-compose-generated.json" << EOF
{
  "docker_compose_file": "services:\\n  simple-mkosi-app:\\n    image: $FULL_IMAGE\\n    ports:\\n      - \\\"3000:3000\\\"\\n    restart: \\\"no\\\"\\n"
}
EOF
```
**Issue**: `\\\"` becomes `\\"` in JSON, which is invalid JSON syntax

## Current Testing Status

### ✅ Completed Tests
1. **mkosi build verification** - Working, creates deterministic images
2. **Registry push verification** - Working, images available on Docker Hub
3. **Local container testing** - Working, app responds correctly
4. **DStack deployment creation** - Working, CVM created successfully
5. **Error diagnosis** - Identified JSON escaping as root cause

### 🔧 Next Steps to Complete
1. **Fix JSON escaping** in `push-mkosi-to-registry.sh`
2. **Regenerate app-compose.json** with correct format
3. **Redeploy to DStack** with fixed configuration
4. **Verify end-to-end functionality** - app accessible via DStack URL
5. **Document complete working workflow**

## File Structure
```
/home/amiller/projects/reproducible-build-playground/
├── scripts/
│   ├── build-mkosi.sh              # Build orchestration
│   ├── push-mkosi-to-registry.sh   # Registry push + file generation (needs JSON fix)
│   └── deploy-mkosi-to-dstack.sh   # DStack deployment wrapper
├── builds/simple-mkosi-app-20250927-602336f/
│   ├── simple-app-mkosi.tar        # mkosi OS image (100MB)
│   ├── registry-info.json          # Registry metadata
│   ├── docker-compose-deploy.yml   # Docker compose format
│   ├── app-compose-generated.json  # DStack format (contains JSON bug)
│   └── build-manifest.json         # Build parameters
├── mkosi.conf                      # mkosi configuration
├── mkosi.build                     # mkosi build script with npm workaround
├── Dockerfile.mkosi                # Docker wrapper for mkosi build
└── vendor/npm/                     # Vendored npm packages (working)
```

## Working Commands Summary
```bash
# Complete build and deploy workflow:
./scripts/build-mkosi.sh
./scripts/push-mkosi-to-registry.sh builds/simple-mkosi-app-*/build-manifest.json docker.io/socrates1024
# Fix JSON bug, then:
phala deploy --node-id 16 --kms-id phala-prod8 --name "app-name" builds/simple-mkosi-app-*/app-compose-generated.json
```

## Final Resolution - Complete Success

**Date:** 2025-09-28
**Status:** ✅ WORKING - Full end-to-end mkosi + DStack deployment successful

### Issues Fixed
1. **JSON escaping bug**: Changed `\\\"3000:3000\\\"` to `"3000:3000"` in docker-compose generation
2. **DStack validation errors**: Switched from complex app-compose.json to simple docker-compose.yml format
3. **Missing command specification**: Added `working_dir` and `command` fields to docker-compose.yml

### Final Working Configuration
```yaml
# docker-compose.yml format for DStack
services:
  simple-mkosi-app:
    image: docker.io/socrates1024/simple-mkosi-app:75d2b9a8612f8f5ee08163b30cd8c9c3f8708c1026da621d0636bd98899db5e6
    ports:
      - "3000:3000"
    restart: "no"
    working_dir: /opt/app
    command: ["/usr/bin/node", "/opt/app/server.js"]
```

### Successful Deployment Results
- **CVM ID**: `b3e97f00-a6e7-400e-83cd-b563c772bc77`
- **App ID**: `7d99bfbfce82f42f718d825266f878bf1735a041`
- **Live App URL**: `https://7d99bfbfce82f42f718d825266f878bf1735a041-3000.dstack-pha-prod8.phala.network`
- **App Response**: `{"message":"Deterministic build practice app","timestamp":"2025-09-28T02:22:32.993Z","nodeVersion":"v18.20.4"}`

### Important URL Format Discovery
- ❌ **Incorrect format**: `{app-id}.pa.phala.network` (doesn't work)
- ✅ **Correct format**: `{app-id}-{port}.dstack-pha-prod8.phala.network`

**The mkosi deterministic build system with DStack deployment is now 100% working end-to-end.**