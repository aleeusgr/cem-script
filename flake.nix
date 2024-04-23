{
  # This is a template created by `hix init`
  inputs.haskellNix.url = "github:input-output-hk/haskell.nix";
  inputs.nixpkgs.follows = "haskellNix/nixpkgs-unstable";
  inputs.flake-utils.url = "github:numtide/flake-utils";
  inputs.CHaP = {
    url = "github:intersectmbo/cardano-haskell-packages?ref=repo";
    flake = false;
  };
  outputs = { self, nixpkgs, flake-utils, haskellNix, CHaP }:
    let
      supportedSystems = [
        "x86_64-linux"
        "x86_64-darwin"
        "aarch64-linux"
        "aarch64-darwin"
      ];
    in
      flake-utils.lib.eachSystem supportedSystems (system:
      let
        overlays = [ haskellNix.overlay
          (final: prev: {
            hixProject =
              final.haskell-nix.hix.project {
                src = ./.;
                evalSystem = "x86_64-linux";
                inputMap = { "https://chap.intersectmbo.org/" = CHaP; };
              };
            haskell-nix = prev.haskell-nix or {} // {
            extraPkgconfigMappings = prev.haskell-nix.extraPkgconfigMappings or {} // {
              "libblst" = [ "libblst" ];
              # map libsoidum to our libsodium-vrf, if you include the iohk-nix
              # crypto overlay, you _do_ want the custom libsoidum.
              "libsodium" = [ "libsodium-vrf" ];
              # for secp256k1, haskell.nix already has that mapping, thus we don't
              # need to inject anything extra here.
            };
          };
          })
        ];
        pkgs = import nixpkgs { inherit system overlays; inherit (haskellNix) config; };
        flake = pkgs.hixProject.flake {};
        # = pkgs.haskell-nix.cabalProject {
        #   src = ./.;
        #   inputMap = { "https://chap.intersectmbo.org/" = CHaP; };
        # };
      in flake // {
        legacyPackages = pkgs;

        packages.default = flake.packages."hello:exe:cem-script";
      });

  # --- Flake Local Nix Configuration ----------------------------
  nixConfig = {
    # This sets the flake to use the IOG nix cache.
    # Nix should ask for permission before using it,
    # but remove it here if you do not want it to.
    extra-substituters = ["https://cache.iog.io"];
    extra-trusted-public-keys = ["hydra.iohk.io:f/Ea+s+dFdN+3Y/G+FDgSq+a5NEWhJGzdjvKNGv0/EQ="];
    allow-import-from-derivation = "true";
  };
}
