{
  description = "Rust stable dev shell (rustc, cargo, rust-analyzer, clippy).";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.05";

  outputs = { self, nixpkgs }: let
    system = "x86_64-linux";
    pkgs = nixpkgs.legacyPackages.${system};
  in {
    devShells.${system}.default = pkgs.mkShell {
      packages = with pkgs; [
        rustc                # the compiler
        cargo                # build/test/install tooling
        rustfmt              # formatter
        clippy               # linter
        rust-analyzer        # LSP server (used by nvim's lspconfig)
        pkg-config           # native crates often need this at link time
        openssl              # ditto for crates that link OpenSSL
      ];

      # rustc default path collides with rustup's; `RUST_SRC_PATH` lets
      # rust-analyzer find the std lib source for go-to-definition.
      RUST_SRC_PATH = "${pkgs.rustPlatform.rustLibSrc}";

      shellHook = ''
        echo "rustc $(rustc --version | cut -d' ' -f2) + cargo $(cargo --version | cut -d' ' -f2)"
      '';
    };
  };
}
