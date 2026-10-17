{
  description = "PadBridge の開発環境";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";

  outputs =
    { nixpkgs, ... }:
    let
      system = "aarch64-darwin";
      pkgs = nixpkgs.legacyPackages.${system};
    in
    {
      # mkShell は Nix の SDK を指す環境変数を立てて xcodebuild を壊すため、mkShellNoCC にする
      devShells.${system}.default = pkgs.mkShellNoCC {
        packages = [ pkgs.xcodegen ];
      };
    };
}
