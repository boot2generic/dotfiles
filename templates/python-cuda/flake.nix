{
  description = "Python + PyTorch + CUDA dev shell for ML/LLM research.";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.05";

  outputs = { self, nixpkgs }: let
    system = "x86_64-linux";
    # CUDA pulls non-free NVIDIA libs — must allow unfree at the
    # nixpkgs level.
    pkgs = import nixpkgs {
      inherit system;
      config = {
        allowUnfree = true;
        cudaSupport = true;       # PyTorch builds with CUDA support
      };
    };
  in {
    devShells.${system}.default = pkgs.mkShell {
      packages = with pkgs; [
        # Use python311 (PyTorch wheels track recent CPython releases;
        # 3.11 has the broadest binary coverage as of nixpkgs 25.05).
        python311

        # `-bin` variants pull prebuilt wheels — way faster than the
        # source build (which can take an hour on the first cold run).
        python311Packages.torch-bin
        python311Packages.torchvision-bin
        python311Packages.numpy
        python311Packages.scipy
        python311Packages.matplotlib
        python311Packages.jupyter
        python311Packages.ipython

        # CUDA toolkit + cuDNN.  PyTorch carries its own bundled
        # versions in the -bin wheels but having the toolkit on PATH
        # is useful for `nvcc`, `nvidia-smi`, custom CUDA kernels.
        cudaPackages.cudatoolkit
        cudaPackages.cudnn

        uv
        ruff
      ];

      shellHook = ''
        echo ""
        echo "Python $(python --version 2>&1 | cut -d' ' -f2) + PyTorch with CUDA"
        python -c 'import torch; print(f"  torch={torch.__version__}, CUDA available={torch.cuda.is_available()}, device count={torch.cuda.device_count()}")' \
          2>/dev/null \
          || echo "  (PyTorch not yet imported — first call will be slow)"
        echo ""
        echo "If first build is slow, add the cuda-maintainers cache to"
        echo "  /etc/nix/nix.conf — see <repo>/readme/nix.md for details."
        echo ""
      '';
    };
  };
}
