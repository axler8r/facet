{
  description = "facet development environment";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-parts.url = "github:hercules-ci/flake-parts";
  };

  outputs =
    inputs@{ flake-parts, ... }:
    flake-parts.lib.mkFlake { inherit inputs; } {
      systems = [
        "x86_64-linux"
        "aarch64-linux"
      ];

      perSystem = { pkgs, ... }: {
        devShells.default = pkgs.mkShell {
          name = "facet";
          packages = [
            pkgs.git
            pkgs.gnumake
            pkgs.nim
            pkgs.nimble
            pkgs.prettier
            pkgs.sqlite
          ];
        };
      };
    };
}
