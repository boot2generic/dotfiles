{
  description = "Python 3.12 development shell with uv and standard tooling.";

  # Pin nixpkgs to a recent stable release.  `nix flake update` bumps
  # this to the latest commit on the same branch.
  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.05";

  outputs = { self, nixpkgs }: let
    system = "x86_64-linux";
    pkgs = nixpkgs.legacyPackages.${system};
  in {
    devShells.${system}.default = pkgs.mkShell {
      packages = with pkgs; [
        python312
        python312Packages.pip
        python312Packages.virtualenv
        uv          # fast pip / venv replacement
        ruff        # linter + formatter (replaces black, isort, flake8)
        # Add project-specific deps below as nix packages OR install via
        # `uv pip install -r requirements.txt` from inside the shell.
      ];

      shellHook = ''
        echo ""
        echo "Python $(python --version 2>&1 | cut -d' ' -f2) + uv $(uv --version 2>&1 | cut -d' ' -f2)"
        echo "Run \`uv pip install <pkg>\` (fast) or \`pip install <pkg>\` for project deps."
        echo ""
      '';
    };
  };
}
