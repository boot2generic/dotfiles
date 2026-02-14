#!/bin/bash

echo "Starting dotfiles installation..."

# Function to detect package manager
detect_package_manager() {
    if command -v apt &> /dev/null; then
        echo "apt"
    elif command -v dnf &> /dev/null; then
        echo "dnf"
    elif command -v pacman &> /dev/null; then
        echo "pacman"
    else
        echo "unknown"
    fi
}

# Function to install packages
install_packages() {
    local package_manager
    package_manager=$(detect_package_manager)
    
    if [ "$package_manager" == "apt" ]; then
        sudo apt update && sudo apt install -y "$@"
    elif [ "$package_manager" == "dnf" ]; then
        sudo dnf install -y "$@"
    elif [ "$package_manager" == "pacman" ]; then
        sudo pacman -Sy --noconfirm "$@"
    else
        echo "Error: No supported package manager (apt, dnf, pacman) found. Please install packages manually."
        exit 1
    fi
}

# Function to check if a package is installed and install it if not
install_if_not_present() {
    for pkg in "$@"; do
        if ! command -v "$pkg" &> /dev/null; then
            echo "$pkg not found. Installing..."
            install_packages "$pkg"
            echo "$pkg installed."
        else
            echo "$pkg is already installed."
        fi
    done
}

echo ""
echo "Installing essential packages..."
install_if_not_present tmux zsh bat ripgrep ffmpeg 7zip jq poppler-utils fd-find ripgrep fzf zoxide imagemagick xclip nnet-tools 

echo ""
echo "Installing Oh My Zsh..."
if [ ! -d "$HOME/.oh-my-zsh" ]; then
    echo "Oh My Zsh not found. Installing..."
    sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)" "" --unattended
    echo "Oh My Zsh installed."
else
    echo "Oh My Zsh is already installed."
fi

# Set zsh as default shell if not already
if [ "$(basename "$SHELL")" != "zsh" ]; then
    read -p "Do you want to set zsh as your default shell? (y/N): " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        chsh -s "$(command -v zsh)"
        echo "zsh has been set as your default shell. Please log out and log back in for changes to take effect."
    fi
fi

echo ""
echo "Setting up ~/.zshrc..."
ZSHRC_FILE="$HOME/.zshrc"

# Add editor and visual variables
if ! grep -q "export EDITOR=nvim" "$ZSHRC_FILE"; then
    echo "export EDITOR=nvim" >> "$ZSHRC_FILE"
    echo "Added 'export EDITOR=nvim' to $ZSHRC_FILE"
else
    echo "'export EDITOR=nvim' already exists in $ZSHRC_FILE"
fi

if ! grep -q "export VISUAL=nvim" "$ZSHRC_FILE"; then
    echo "export VISUAL=nvim" >> "$ZSHRC_FILE"
    echo "Added 'export VISUAL=nvim' to $ZSHRC_FILE"
else
    echo "'export VISUAL=nvim' already exists in $ZSHRC_FILE"
fi

# Add alias for cat to batcat
if command -v batcat &> /dev/null; then
    if ! grep -q "alias cat='batcat'" "$ZSHRC_FILE"; then
        echo "alias cat='batcat'" >> "$ZSHRC_FILE"
        echo "Added 'alias cat=\"batcat\"' to $ZSHRC_FILE"
    else
        echo "'alias cat=\"batcat\"' already exists in $ZSHRC_FILE"
    fi
elif command -v bat &> /dev/null; then
    if ! grep -q "alias cat='bat'" "$ZSHRC_FILE"; then
        echo "alias cat='bat'" >> "$ZSHRC_FILE"
        echo "Added 'alias cat=\"bat\"' to $ZSHRC_FILE"
    else
        echo "'alias cat=\"bat\"' already exists in $ZSHRC_FILE"
    fi
fi

echo ""
echo "Installing tmux.conf to your home directory..."

# Get the directory where the script is located
SCRIPT_DIR="$(dirname "$(readlink -f "$0")")"

# Copy .tmux.conf to the home directory
cp "$SCRIPT_DIR/tmux.conf" "$HOME/.tmux.conf"

echo "tmux.conf has been copied to $HOME/.tmux.conf"

echo ""
echo "Installing Neovim configuration..."

# Create Neovim config directory if it doesn't exist
mkdir -p "$HOME/.config/nvim"

# Copy nvim.lua to the Neovim config directory as init.lua
cp "$SCRIPT_DIR/nvim.lua" "$HOME/.config/nvim/init.lua"

echo "nvim.lua has been copied to $HOME/.config/nvim/init.lua"

echo ""
echo "Checking Neovim version..."

MIN_NVIM_VERSION="0.8.0"
CURRENT_NVIM_VERSION=$(nvim --version | head -n 1 | awk '{print $2}' 2>/dev/null)

if [ -z "$CURRENT_NVIM_VERSION" ] || printf '%s\n' "$MIN_NVIM_VERSION" "$CURRENT_NVIM_VERSION" | sort -V -C; then
    echo "Neovim version is less than $MIN_NVIM_VERSION or not found. Install Latest Version to use Config"
    echo "https://github.com/neovim/neovim/releases/"
else
    echo "Neovim version ($CURRENT_NVIM_VERSION) is already $MIN_NVIM_VERSION or newer."
fi

echo ""
echo "Installing lazy.nvim..."

# Check if lazy.nvim is installed
if [ ! -d "$HOME/.local/share/nvim/lazy/lazy.nvim" ]; then
    echo "lazy.nvim not found. Cloning it now..."
    git clone --filter=blob:none https://github.com/folke/lazy.nvim.git \
        --branch=stable "$HOME/.local/share/nvim/lazy/lazy.nvim"
    echo "lazy.nvim cloned to $HOME/.local/share/nvim/lazy/lazy.nvim"
else
    echo "lazy.nvim is already installed."
fi

echo ""
# Check if TPM (Tmux Plugin Manager) is installed
if [ ! -d "$HOME/.tmux/plugins/tpm" ]; then
    echo "TPM (Tmux Plugin Manager) not found. Cloning it now..."
    git clone https://github.com/tmux-plugins/tpm "$HOME/.tmux/plugins/tpm"
    echo "TPM cloned to $HOME/.tmux/plugins/tpm"
else
    echo "TPM is already installed."
fi

echo "Installation complete."
