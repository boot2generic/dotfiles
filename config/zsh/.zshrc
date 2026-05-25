# ============================================================
# Zsh Configuration — Cyberpunk Neon
# Deployed to: ~/.zshrc
# Requires: oh-my-zsh, zsh-autosuggestions, zsh-syntax-highlighting,
#           starship, fzf
# ============================================================

# ── oh-my-zsh setup ──────────────────────────────────────────
export ZSH="$HOME/.oh-my-zsh"

# Theme is handled by Starship — OMZ theme is left blank
ZSH_THEME=""

# Plugins (cloned to ~/.oh-my-zsh/custom/plugins/ by install script)
plugins=(
    git
    sudo                      # double-Escape to prepend sudo
    colored-man-pages         # color man pages
    command-not-found         # suggest package when command missing
    docker
    fzf                       # fzf key bindings and completion
    zsh-autosuggestions       # fish-style inline suggestions
    zsh-syntax-highlighting   # real-time command syntax coloring
)

source "$ZSH/oh-my-zsh.sh"

# ── Environment ──────────────────────────────────────────────
export LANG=en_US.UTF-8
export LC_ALL=en_US.UTF-8

# Default editor: neovim
export EDITOR=nvim
export VISUAL=nvim
export MANPAGER="nvim +Man!"   # use nvim to render man pages

# XDG base dirs
export XDG_CONFIG_HOME="$HOME/.config"
export XDG_DATA_HOME="$HOME/.local/share"
export XDG_CACHE_HOME="$HOME/.cache"

# Local binaries
export PATH="$HOME/.local/bin:$PATH"

# VPN split-tunnel shim dir.  Managed by scripts/vpn-exclude.sh — each
# file in there is a wrapper that exec's `mullvad-exclude <real-binary>`
# so the app bypasses the Mullvad tunnel.  We prepend the dir BEFORE
# ~/.local/bin so shims for tools installed under ~/.local/bin (e.g.
# claude, installed via npm) still get intercepted.
[[ -d "$HOME/.local/bin/vpn-excluded" ]] && \
  export PATH="$HOME/.local/bin/vpn-excluded:$PATH"

# /usr/sbin houses tools we *use* as a regular user — `tlp-stat`,
# `iw dev`, `rfkill list`, `powertop`, `nft list ruleset`, …  Debian's
# default /etc/profile only adds /usr/sbin for root, which makes the
# bare commands in `readme/system.md` and friends silently fail for
# everyone else.  Append (don't prepend) so /usr/bin still wins on the
# rare collision.
case ":$PATH:" in
  *":/usr/sbin:"*) ;;
  *) export PATH="$PATH:/usr/sbin" ;;
esac

# ── History ──────────────────────────────────────────────────
HISTSIZE=50000
SAVEHIST=50000
HISTFILE="$HOME/.zsh_history"

setopt HIST_IGNORE_ALL_DUPS    # de-duplicate history
setopt HIST_IGNORE_SPACE       # don't save commands starting with space
setopt EXTENDED_HISTORY        # save timestamp + duration

# Per-pane up-arrow, shared search.
#
# We deliberately do NOT enable SHARE_HISTORY.  SHARE_HISTORY makes
# every shell import other shells' commands into its in-memory
# history on every prompt, which means up-arrow in tmux pane A walks
# through commands typed in pane B / window C / yesterday's session.
# That breaks the "up-arrow = stuff I just typed here" muscle memory.
#
# INC_APPEND_HISTORY writes each command to $HISTFILE the moment it
# runs, so the disk file contains everything from every pane — but
# the in-memory history of each shell stays per-pane.  Up-arrow then
# only walks THIS pane's commands.
#
# Ctrl-r still searches across panes via the custom fzf widget at the
# bottom of this file (history-fzf-disk-widget), which reads $HISTFILE
# directly without merging it into the running shell's in-memory history.
setopt INC_APPEND_HISTORY      # write to $HISTFILE immediately, no merge

# SECURITY: never persist commands that look like they contain credentials.
# zsh checks every command line against this glob; a match drops the line
# on the floor (not even kept in RAM history).  Combined with
# HIST_IGNORE_SPACE, you can either prefix the command with a space or
# trust the pattern below to catch the obvious cases.
HISTORY_IGNORE='(*PASSWORD*|*PASSWD*|*TOKEN*|*SECRET*|*API_KEY*|*PRIVATE_KEY*|mullvad account login*|wg set * private-key*|export *_KEY=*|export *PASS*=*|gpg --pinentry-mode*)'

# Tighten history-file permissions on shell start.  Many CLI tools
# (zsh, less, python, sqlite, mysql, gdb, …) create their history
# files with mode 0644 — readable by group/other.  Any of these can
# accidentally capture a credential the user typed without a leading
# space.  Forcing 0600 on shell start closes that gap consistently.
for _hist in \
    "$HISTFILE" \
    "$HOME/.fzf_history" \
    "$HOME/.python_history" \
    "$HOME/.lesshst" \
    "$HOME/.sqlite_history" \
    "$HOME/.mysql_history" \
    "$HOME/.psql_history" \
    "$HOME/.gdb_history" \
    "$HOME/.lua_history"; do
    [[ -f "$_hist" ]] && chmod 600 "$_hist" 2>/dev/null
done
unset _hist

# ── Completion ───────────────────────────────────────────────
setopt AUTO_MENU               # show menu after second Tab
setopt COMPLETE_IN_WORD
setopt ALWAYS_TO_END

zstyle ':completion:*' menu select
zstyle ':completion:*' matcher-list 'm:{a-zA-Z}={A-Za-z}'  # case-insensitive
zstyle ':completion:*' list-colors "${(s.:.)LS_COLORS}"

# ── fzf ──────────────────────────────────────────────────────
[ -f ~/.fzf.zsh ] && source ~/.fzf.zsh

# Cyberpunk fzf color palette
export FZF_DEFAULT_OPTS="
  --color=bg+:#1a1a2e,bg:#0d0d1a,spinner:#00e5ff,hl:#00e5ff
  --color=fg:#e2e2ff,header:#00e5ff,info:#ff00cc,pointer:#00e5ff
  --color=marker:#00ff41,fg+:#e2e2ff,prompt:#00e5ff,hl+:#00ff41
  --color=border:#00e5ff
  --border=rounded
  --prompt='  '
  --pointer=' '
  --marker='● '
  --height=60%
  --layout=reverse
  --info=inline
"

# Use ripgrep for fzf default command if available, else fd, else find
if command -v rg &>/dev/null; then
    export FZF_DEFAULT_COMMAND='rg --files --hidden --glob "!.git"'
elif command -v fd &>/dev/null; then
    export FZF_DEFAULT_COMMAND='fd --type f --hidden --exclude .git'
fi

export FZF_CTRL_T_COMMAND="$FZF_DEFAULT_COMMAND"
export FZF_ALT_C_OPTS="--preview 'ls -la {}'"

# ── Aliases ──────────────────────────────────────────────────
# Editor
alias vim='nvim'
alias vi='nvim'
alias v='nvim'

# ls
alias ls='ls --color=auto'
alias ll='ls -alFh'
alias la='ls -A'
alias l='ls -lh'
alias lt='ls -alFht'          # sort by time

# Navigation
alias ..='cd ..'
alias ...='cd ../..'
alias ....='cd ../../..'
alias ~='cd ~'

# grep
alias grep='grep --color=auto'
alias fgrep='fgrep --color=auto'
alias egrep='egrep --color=auto'

# Git shortcuts
alias g='git'
alias gs='git status'
alias ga='git add'
alias gc='git commit'
alias gp='git push'
alias gl='git log --oneline --graph --all'
alias gd='git diff'

# tmux
alias t='tmux'
alias ta='tmux attach -t'
alias tl='tmux list-sessions'
alias tn='tmux new-session -s'

# System
alias free='free -h'
alias top='btop'
alias ports='ss -tulpn'

# ── bat (pretty cat with syntax highlighting) ─────────────────
# Debian ships bat as 'batcat'; ~/.local/bin/bat is symlinked by install script
if command -v bat &>/dev/null; then
    alias cat='bat --paging=never'
    alias catp='bat'               # paged version
elif command -v batcat &>/dev/null; then
    alias cat='batcat --paging=never'
    alias bat='batcat'
    alias catp='batcat'
fi

# ── grc (generic colouriser) ─────────────────────────────────
if command -v grc &>/dev/null; then
    alias netstat='grc netstat'
    alias ping='grc ping'
    alias traceroute='grc traceroute'
    alias ps='grc ps'
    alias df='grc df -h'
    alias du='grc du -h'
    alias ifconfig='grc ifconfig'
    alias ip='grc ip'
    alias dig='grc dig'
    alias lsblk='grc lsblk'
    alias lspci='grc lspci'
else
    alias df='df -h'
    alias du='du -h'
fi

# Reload shell config
alias reload='source ~/.zshrc'
alias zshconfig='nvim ~/.zshrc'

# ── Functions ────────────────────────────────────────────────

# mkcd: mkdir -p + cd in one step.  Takes a single path (which may be
# nested, e.g. `mkcd foo/bar/baz`).  The previous implementation used
# "$@" for both mkdir and cd, which silently broke when called with
# multiple args (cd takes exactly one positional argument).
mkcd() { mkdir -p "$1" && cd "$1"; }

# set-title: rename the terminal window's title bar (the strip i3 /
# your task switcher show at the top of the alacritty window).  Emits
# OSC 0/2 escape sequences that any compliant terminal (alacritty,
# kitty, gnome-terminal, xterm, …) honours; that title flows into
# i3's title bar.
#
#   set-title "Working on widget feature"   # sticky title
#   set-title                                # restore auto-titling
#
# Why NOT named `title`: oh-my-zsh defines its own `title` function
# in lib/termsupport.zsh and calls it from precmd/preexec hooks every
# time you press Enter — passing prompt-escape format strings like
# `%15<..<%~%<<` as arguments.  An override of `title` named the same
# would be invoked by those hooks too, and a naive `printf` body
# would set the title bar to the literal `%~` text.  Using a
# different name keeps OMZ's `title` intact and avoids that bug.
#
# We toggle `DISABLE_AUTO_TITLE` so OMZ's `precmd_functions` skip
# their auto-update — without that, the title we just set would be
# overwritten on the next prompt.  `set-title` (no args) unsets the
# flag and OMZ resumes managing the title (showing cwd / current
# command).
#
# `print -Pn` (vs `printf`) handles the escape sequences AND zsh
# prompt-escape expansion correctly.  OSC 0 + OSC 2 are sent for
# maximum terminal compatibility, plus the tmux variant if we're
# inside a tmux session (so the tmux status bar shows the new name).
set-title() {
    # Accept the title as either a single quoted argument or as
    # whitespace-separated words: `set-title widget feature` and
    # `set-title "widget feature"` both work.  $* joins all
    # positional args with the first IFS char (default space).
    local _title="$*"
    if [[ -z "$_title" ]]; then
        unset DISABLE_AUTO_TITLE
        echo "set-title: oh-my-zsh auto-title restored"
    else
        export DISABLE_AUTO_TITLE=true
        print -Pn "\e]0;${_title}\a"
        print -Pn "\e]2;${_title}\a"
        if [[ -n "$TMUX" ]]; then
            print -Pn "\ek${_title}\e\\"
        fi
    fi
}

# Hotkey: Ctrl-X t — prefill `set-title ` on the command line, ready
# for you to type the new title and press Enter.
#
# Why this combo: Ctrl-X starts an "extended" chord in zsh's default
# emacs key map, and Ctrl-X t is unbound in stock zsh and oh-my-zsh.
# Avoided alternatives:
#   • Alt-T  → bound to `transpose-words` (swap adjacent words)
#   • Ctrl-T → fzf file picker
#   • Alt-C  → fzf cd-to-directory
# So Ctrl-X t doesn't collide with anything you're already using.
#
# How it works: we replace the editor buffer with `set-title ` and
# put the cursor at the end.  Anything you'd already typed at the
# prompt is lost — but Ctrl-X t isn't easy to hit by accident.
_zle-set-title-prefix() {
    BUFFER='set-title '
    CURSOR=${#BUFFER}
}
zle -N _zle-set-title-prefix
bindkey '^Xt' _zle-set-title-prefix

# ff: fzf-find a file and open in nvim
ff() {
    local file
    file=$(find "${1:-.}" -type f 2>/dev/null \
        | fzf --preview 'head -100 {}' \
              --preview-window=right:60%:wrap \
              --prompt='Open > ')
    [ -n "$file" ] && nvim "$file"
}

# fcd: fzf-find a directory and cd into it
fcd() {
    local dir
    dir=$(find "${1:-.}" -type d 2>/dev/null \
        | fzf --prompt='cd > ')
    [ -n "$dir" ] && cd "$dir"
}

# fcp: fzf-find a file and copy its path to clipboard
fcp() {
    local path
    path=$(find "${1:-.}" 2>/dev/null \
        | fzf --prompt='Copy path > ')
    [ -n "$path" ] && echo -n "$path" | xclip -selection clipboard && echo "Copied: $path"
}

# ── Nix package manager (optional, opt-in) ───────────────────
# Sourced by /etc/profile.d/nix.sh after a multi-user `local_setup.sh
# install_nix` run.  Plain `apt`-only systems silently skip — none of
# this fires unless Nix is installed.  The hook chain:
#   • /etc/profile.d/nix.sh         → puts `nix`, `~/.nix-profile/bin`
#                                      on PATH for every login shell.
#   • direnv hook                   → makes `cd <project>` notice an
#                                      .envrc file in the dir.
#   • ~/.config/direnv/direnvrc     → sources nix-direnv's `use flake`
#                                      so `.envrc` containing `use flake`
#                                      auto-activates the project's
#                                      Nix dev shell on cd, and tears
#                                      it down on cd-out.  Cached
#                                      between invocations so it's fast.
# Starter flakes live in <repo>/templates/.  See README for the model.
if command -v direnv >/dev/null 2>&1; then
    eval "$(direnv hook zsh)"
fi

# ── Ctrl-r: search FULL on-disk history (not just this pane) ──
# Pairs with the INC_APPEND_HISTORY / no-SHARE_HISTORY policy at the
# top of this file.  Up-arrow walks only commands typed in THIS pane
# (in-memory history); Ctrl-r reads $HISTFILE directly so it sees
# every command from every pane / session ever — without polluting
# the in-memory history (so up-arrow stays per-pane).
#
# Defined AFTER `~/.fzf.zsh` (which would otherwise bind ^R to the
# default fzf-history-widget that reads in-memory history only).
history-fzf-disk-widget() {
    local selected
    # zsh extended_history format: lines look like
    #     ": 1234567890:0;ls -la"
    # Strip the timestamp prefix when present, leave plain lines alone.
    # awk dedupes while preserving order; tac reverses to put most-
    # recent commands at the top of the fzf list.
    selected="$(
        sed -E 's/^: [0-9]+:[0-9]+;//' "$HISTFILE" 2>/dev/null \
          | awk '!seen[$0]++' \
          | tac \
          | fzf --height=40% --layout=reverse --tiebreak=index \
                --query "$LBUFFER" --no-multi --exit-0 \
                --prompt='history (all panes)> '
    )"
    if [[ -n "$selected" ]]; then
        LBUFFER="$selected"
    fi
    zle reset-prompt
}
zle -N history-fzf-disk-widget
bindkey '^R' history-fzf-disk-widget

# ── Starship prompt ───────────────────────────────────────────
export STARSHIP_CONFIG="$HOME/.config/starship/starship.toml"
eval "$(starship init zsh)"
