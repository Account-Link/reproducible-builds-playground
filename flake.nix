{
  description = "Simple deterministic app - Nix version";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-23.05";
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

          # Exact npm dependency hash (calculated from first build attempt)
          npmDepsHash = "sha256-3gDC1dnnQ1YMebOo5v0wqz357SawcBkvPrXfOfZpv1c=";

          # No build step needed, just install dependencies
          dontNpmBuild = true;

          buildInputs = with pkgs; [
            curl  # System dependency
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

        # Container image
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