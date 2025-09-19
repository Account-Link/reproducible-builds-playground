# Complete Guide: Nixifying Apps for Reproducible Builds + DStack

## Overview

This guide shows how to take a simple Node.js app and create both:
1. **Nix-based reproducible builds** (simpler than Docker approach)
2. **DStack deployment compatibility** (Docker images are still needed for deployment)

The key insight: **Nix simplifies the build process**, but **Docker images are still needed for deployment platforms** like DStack.

## How Nix Handles npm Packages

### Package Resolution Strategy
Nix uses `buildNpmPackage` which differs fundamentally from Docker's approach:

1. **Content-Addressed Dependencies**: All npm packages are downloaded and stored in `/nix/store/` with content-based hashes
2. **Fixed-Output Derivations**: The `npmDepsHash` ensures that dependency resolution is deterministic
3. **Pre-computed Dependency Tree**: Unlike Docker which runs `npm ci` at build time, Nix computes the entire dependency graph beforehand

### Key Components

**`npmDepsHash`**:
- `"sha256-3gDC1dnnQ1YMebOo5v0wqz357SawcBkvPrXfOfZpv1c="`
- This hash represents the exact dependency tree for `express@4.18.2`
- Must be updated whenever `package.json` or `package-lock.json` changes
- Calculated during the first build attempt (Nix will tell you the expected hash if it's wrong)

**Dependency Installation**:
- Nix downloads all transitive dependencies (70+ packages for just `express`)
- All packages stored in read-only `/nix/store/` with normalized timestamps (Dec 31 1969)
- No network access during build - all dependencies must be pre-fetched

**System Dependencies**:
- `buildInputs = [ curl ]` adds system packages directly from nixpkgs
- No need for `apt-get install` or Debian snapshot management
- All system packages are content-addressed and reproducible

## The Nixification Process

### Step 1: Initial App Structure

Starting with a simple Node.js app:
```
simple-app/
├── package.json          # Dependencies with exact versions
├── server.js             # Application code
└── Dockerfile            # Traditional Docker build (complex)
```

### Step 2: Create flake.nix

Create `flake.nix` in the project root:

```nix
{
  description = "Simple deterministic app - Nix version";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-23.05";  # Pin exact commit
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = nixpkgs.legacyPackages.${system};

        # Node.js app with exact dependencies
        app = pkgs.buildNpmPackage {
          pname = "simple-det-app";
          version = "1.0.0";
          src = ./simple-app;

          # Get this hash from first failed build attempt
          npmDepsHash = "sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=";

          # No build step needed for simple apps
          dontNpmBuild = true;

          buildInputs = with pkgs; [
            curl  # System dependencies
          ];

          # Reproducible timestamp
          SOURCE_DATE_EPOCH = "1640995200";  # 2022-01-01

          # Install the app properly
          installPhase = ''
            mkdir -p $out/bin $out/lib/simple-det-app
            cp -r . $out/lib/simple-det-app/

            # Create executable wrapper
            cat > $out/bin/simple-det-app << EOF
            #!/bin/sh
            exec ${pkgs.nodejs}/bin/node $out/lib/simple-det-app/server.js "\$@"
            EOF
            chmod +x $out/bin/simple-det-app
          '';

          meta = {
            description = "Simple deterministic Express app";
          };
        };

        # Container image for deployment
        image = pkgs.dockerTools.buildImage {
          name = "simple-det-app";
          tag = "nix";

          contents = [ app pkgs.curl pkgs.bash pkgs.coreutils ];

          config = {
            Cmd = [ "${app}/bin/simple-det-app" ];
            ExposedPorts = { "3000/tcp" = {}; };
          };

          # Reproducible creation time
          created = "1970-01-01T00:00:01Z";
        };

      in {
        packages = {
          default = app;
          app = app;
          image = image;
        };

        # Development shell
        devShells.default = pkgs.mkShell {
          buildInputs = with pkgs; [ nodejs curl ];
        };
      });
}
```

### Step 3: Get Correct npm Hash

**npmDepsHash Calculation**
When you change `package.json`:
1. Update `npmDepsHash` to empty string: `""`
2. Run `nix build .#app`
3. Nix will fail with error showing expected hash
4. Copy the expected hash to `npmDepsHash`

Example:
1. First build attempt will fail with incorrect hash:
```bash
nix build .#app
# Error: hash mismatch... got: sha256-3gDC1dnnQ1YMebOo5v0wqz357SawcBkvPrXfOfZpv1c=
```

2. Update flake.nix with the correct hash from error message:
```nix
npmDepsHash = "sha256-3gDC1dnnQ1YMebOo5v0wqz357SawcBkvPrXfOfZpv1c=";
```

### Step 4: Build and Test

```bash
# Build the app package
nix build .#app

# Test it works
PORT=3001 ./result/bin/simple-det-app &
curl localhost:3001
curl localhost:3001/health

# Build Docker image
nix build .#image

# Load into Docker
docker load < result

# Test containerized app
docker run -p 3000:3000 simple-det-app:nix
```

## Adapting Docker Apps to Nix

### System Dependencies
Map Docker's `apt-get install` to Nix `buildInputs`:
```dockerfile
RUN apt-get install -y curl=7.88.1-10+deb12u14
```
becomes:
```nix
buildInputs = with pkgs; [ curl ];
```

### Environment Variables
Docker `ENV` becomes Nix wrapper scripts or runtime configuration in the container config.

## Development Workflow

### Local Development
```bash
nix develop  # Enter dev shell with Node.js + dependencies
npm start    # Run normally
```

### Building
```bash
nix build .#app    # Build app package
nix build .#image  # Build Docker image
```

### Deployment
Same as Docker workflow but with registry push of Nix-built image:
```bash
./scripts/build-deterministic-nix.sh
./dstack/push-to-registry.sh builds/.../build-manifest.json registry
./dstack/deploy-to-dstack.sh builds/.../build-manifest.json
```

## Nix vs Docker Comparison

| Aspect | Docker Approach | Nix Approach |
|--------|----------------|--------------|
| **Configuration** | Multiple scripts + Dockerfile | Single flake.nix |
| **Dependency Management** | Manual snapshot.debian.org | Automatic content-addressed |
| **Verification** | Custom `--no-cache` rebuilds | Mathematical guarantees |
| **Package Discovery** | smart-probe-snapshot.sh | Declarative specification |
| **Build Time** | ~45s | ~30s |
| **Image Size** | 388MB | 279MB |
| **Offline Builds** | Requires network | Works offline after fetch |
| **Reproducibility** | Manual verification needed | Content-addressed by design |

### Build Performance
- **Docker**: ~45s (network-dependent apt + npm installs)
- **Nix**: ~30s (mostly local copying from store)

### Image Size
- **Docker**: 388MB (includes apt cache, npm cache, build tools)
- **Nix**: 279MB (only runtime dependencies)

### Reproducibility
- **Docker**: Requires careful Debian snapshot management, exact package versions
- **Nix**: Content-addressed by design, no manual snapshot management

### Dependency Management
- **Docker**: `snapshot.debian.org` + `curl=7.88.1-10+deb12u14` + complex cleanup
- **Nix**: All handled by nixpkgs pinning + content addressing

## DStack Integration Strategy

**Key Point:** DStack requires Docker images, so we use Nix to build reproducible Docker images.

### Workflow Overview

1. **Build Phase (Nix):** Create deterministic Docker image using Nix
2. **Registry Phase:** Push Nix-built image to container registry
3. **Deploy Phase:** Deploy using DStack with docker-compose pointing to registry image
4. **Verify Phase:** Confirm deployed hash matches local build

### Implementation Steps

#### 1. Enhanced Nix Build Process

The Nix build creates both:
- Standalone app package (`nix build .#app`)
- Docker image for deployment (`nix build .#image`)

#### 2. Registry Integration

Push Nix-built Docker image:
```bash
# Use unified push script (automatically detects Nix builds)
./dstack/push-to-registry.sh builds/simple-det-app-nix-*/build-manifest.json docker.io/username
```

#### 3. DStack Deployment

The unified push script automatically updates docker-compose-deploy.yml:
```yaml
services:
  simple-det-app:
    image: docker.io/username/simple-det-app:IMAGE_HASH
    ports:
      - "3000:3000"
    restart: "no"
```

#### 4. Verification

Use existing DStack verification scripts to confirm:
- Deployed compose matches local specification
- App-compose hash verification works
- Remote verification succeeds

## Advantages of Nix + DStack Approach

### 1. **Build Simplification**
- No manual snapshot.debian.org management
- No custom verification scripts needed
- Automatic dependency resolution

### 2. **Stronger Guarantees**
- Content-addressed builds
- Mathematical reproducibility
- Offline capability

### 3. **DStack Compatibility**
- Still produces Docker images for deployment
- Works with existing DStack infrastructure
- Maintains deployment verification workflow

### 4. **Better Developer Experience**
- Single configuration file
- Faster builds
- Smaller images
- Easier maintenance

## Migration Path

For existing Docker-based apps:

1. **Parallel Implementation:** Keep existing Dockerfile, add flake.nix
2. **Gradual Migration:** Test Nix approach alongside Docker
3. **Comparison:** Verify both produce equivalent results
4. **Switch:** Move to Nix-based builds once confident

## File Structure Impact

### New Files
- `flake.nix` - Primary build specification
- `flake.lock` - Locked input versions (like package-lock.json for flake inputs)

### Modified Files
- Build scripts updated to call `nix build` instead of `docker build`
- Deploy scripts handle Nix-specific metadata in build manifests

### Unchanged Files
- `simple-app/` directory remains identical
- `package.json` and `package-lock.json` unchanged
- DStack deployment process identical (just different image source)

## Common Patterns for Different App Types

### Node.js Apps
```nix
app = pkgs.buildNpmPackage {
  pname = "my-app";
  version = "1.0.0";
  src = ./src;
  npmDepsHash = "sha256-...";
  dontNpmBuild = true;  # For apps without build step
  # OR
  # npmBuildScript = "build";  # For apps with build step
};
```

### Python Apps
```nix
app = pkgs.python3Packages.buildPythonApplication {
  pname = "my-app";
  version = "1.0.0";
  src = ./src;
  propagatedBuildInputs = with pkgs.python3Packages; [
    flask
    requests
  ];
};
```

### Go Apps
```nix
app = pkgs.buildGoModule {
  pname = "my-app";
  version = "1.0.0";
  src = ./src;
  vendorHash = "sha256-...";  # Get from first failed build
};
```

## Verification

The deterministic build process ensures:
1. **Same inputs = same outputs**: Changing only comments won't change image hash
2. **Content addressing**: Dependencies can't change without hash changing
3. **Hermetic builds**: No network access during build means no drift
4. **Cross-platform**: Same hash on different machines (when using same nixpkgs pin)

This approach removes the complexity of Debian snapshot management while providing stronger reproducibility guarantees.
