{
  description = "Node.js 20 + pnpm + TypeScript dev shell.";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.05";

  outputs = { self, nixpkgs }: let
    system = "x86_64-linux";
    pkgs = nixpkgs.legacyPackages.${system};
  in {
    devShells.${system}.default = pkgs.mkShell {
      packages = with pkgs; [
        nodejs_20
        pnpm
        nodePackages.typescript
        nodePackages.typescript-language-server   # for nvim/lspconfig
        # Bun/Deno are also available as pkgs.bun / pkgs.deno if you
        # prefer them — uncomment to swap.
      ];

      shellHook = ''
        echo "Node $(node --version) / pnpm $(pnpm --version) / tsc $(tsc --version | cut -d' ' -f2)"
      '';
    };
  };
}
