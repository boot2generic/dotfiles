# Neovim — Editor

Modal editor with LSP, treesitter syntax highlighting, fuzzy file/buffer/grep
search, autocomplete, git gutter, file tree, and a snappy startup. All plugins
are pinned to versions that work on **nvim 0.10+** (Debian 13's stock nvim).

**Config:** `~/.config/nvim/init.lua` (single-file Lua config)
**Plugin manager:** [`lazy.nvim`](https://github.com/folke/lazy.nvim) — auto-bootstraps on first run
**Leader key:** **`Space`**

---

## First-time setup

The dotfiles install runs `:Lazy! sync` and `:TSUpdateSync` headlessly during
provisioning, so first launch is instant. If you ever land on a fresh machine
without the install scripts:

```bash
nvim --headless '+Lazy! sync' '+TSUpdateSync' +qa
```

Inside nvim, useful first commands:
| Command          | Action                                                   |
|------------------|----------------------------------------------------------|
| `:Lazy`          | Open the plugin manager UI                               |
| `:Mason`         | Manage LSP / formatter / linter servers                  |
| `:checkhealth`   | Diagnose plugin/runtime issues                           |
| `:TSUpdate`      | Update treesitter parsers                                |
| `:TSInstallInfo` | List parsers (installed vs available)                    |

---

## File / buffer navigation (telescope)

| Keys              | Action                              |
|-------------------|-------------------------------------|
| `<leader>ff`      | Find files                          |
| `<leader>fg`      | Live grep across project            |
| `<leader>fb`      | Open buffers                        |
| `<leader>fh`      | Help tags                           |
| `<leader>fr`      | Recently-opened files               |
| `<leader>fs`      | LSP document symbols                |
| `<leader>/`       | Fuzzy-find inside current buffer    |

---

## File tree

| Keys              | Action                              |
|-------------------|-------------------------------------|
| `<leader>e`       | Toggle file tree                    |
| `<leader>ef`      | Find current file in the tree       |

Inside the tree:
- `Enter` opens, `o` opens (and stays in tree), `O` recursively expand
- `a` create, `r` rename, `d` delete, `x`/`p` cut/paste
- `g?` show all bindings

---

## LSP (Language Server Protocol)

Mason auto-installs these on first launch:

| Server             | Languages                |
|--------------------|--------------------------|
| pyright            | Python                   |
| clangd             | C / C++                  |
| rust-analyzer      | Rust                     |
| lua-language-server| Lua                      |
| intelephense       | PHP                      |
| html-lsp           | HTML                     |
| json-lsp           | JSON                     |
| yaml-language-server| YAML                    |

LSP keybinds (active when an LSP attaches to the buffer):

| Keys              | Action                              |
|-------------------|-------------------------------------|
| `gd`              | Go to definition                    |
| `gD`              | Go to declaration                   |
| `gI`              | Go to implementation                |
| `gr`              | List references                     |
| `K`               | Hover docs                          |
| `<leader>rn`      | Rename symbol                       |
| `<leader>ca`      | Code action                         |
| `<leader>ld`      | Show diagnostics for current line   |
| `[d` / `]d`       | Previous / next diagnostic          |

To install a server not on the list: `:Mason`, find the server, press `i`.

---

## Autocomplete (cmp + LuaSnip)

Active in insert mode whenever the popup appears:

| Keys              | Action                              |
|-------------------|-------------------------------------|
| `Tab`             | Next item / expand snippet          |
| `Shift+Tab`       | Previous item                       |
| `Ctrl-n` / `C-p`  | Next / previous (alt to Tab)        |
| `Enter`           | Confirm selection                   |
| `Ctrl-Space`      | Trigger completion manually         |
| `Ctrl-d` / `C-f`  | Scroll docs in the popup            |
| `Ctrl-e`          | Abort                               |

Snippets come from `friendly-snippets` (VSCode-style). Available snippet names
appear in the completion popup; tab to expand.

---

## Treesitter (syntax + structure)

Already installed parsers: bash, c, cpp, html, javascript, json, lua,
markdown, markdown_inline, php, python, rust, toml, vim, vimdoc, yaml.

> Note: `typescript` is intentionally omitted — its upstream parser source has
> a known typo (`anon_syi_STAR`) that breaks compilation. Re-add once fixed.

Incremental selection (mind-blowingly useful for refactoring):

| Keys              | Action                                          |
|-------------------|-------------------------------------------------|
| `Ctrl-Space`      | Start selection / expand to next node           |
| `Ctrl-s`          | Expand selection to enclosing scope             |
| `Alt-Space`       | Shrink selection                                |

Add a parser: `:TSInstall <lang>`. List available: `:TSInstallInfo`.

---

## Git (gitsigns)

Signs in the gutter show added / changed / deleted lines.

| Keys              | Action                              |
|-------------------|-------------------------------------|
| `]g` / `[g`       | Next / previous hunk                |
| `<leader>gb`      | Blame the current line              |
| `<leader>gd`      | Diff current file                   |

---

## Movement / refactoring helpers

| Keys              | Action                                  |
|-------------------|-----------------------------------------|
| `s`               | Flash jump (label any visible char)     |
| `S`               | Flash jump using treesitter nodes       |
| `<S-l>`           | Next buffer                             |
| `<S-h>`           | Previous buffer                         |
| `<leader>bd`      | Delete buffer                           |
| `<C-h/j/k/l>`     | Move between splits (also tmux-aware)   |
| `Alt+j` / `Alt+k` | Move selected lines down / up (visual)  |

`gcc` (Comment.nvim) toggles a line comment; `gc{motion}` comments a region.
`cs"'` (nvim-surround) changes surrounding `"` to `'` on the cursor word.

---

## Top-level keymaps

| Keys              | Action                              |
|-------------------|-------------------------------------|
| `<leader>w`       | Save                                |
| `<leader>q`       | Quit                                |
| `<leader>Q`       | Quit all (no save)                  |
| `<leader>nc`      | Edit `init.lua`                     |
| `Esc`             | Clear search highlight              |

---

## Plugin list

Top-level plugins (see `init.lua` for the full set):

- **cyberdream** — colorscheme matching the rest of the dotfiles
- **nvim-treesitter** — syntax + indentation
- **telescope.nvim** + **telescope-fzf-native** — fuzzy finder
- **nvim-tree.lua** — file explorer
- **lualine.nvim** + **bufferline.nvim** — statusline + tab bar
- **nvim-lspconfig** + **mason.nvim** + **mason-lspconfig** — LSP
- **fidget.nvim** — LSP progress notifications
- **nvim-cmp** + **LuaSnip** + **friendly-snippets** — autocomplete + snippets
- **gitsigns.nvim** — git status in gutter
- **nvim-autopairs** — auto-close brackets
- **Comment.nvim** — toggle comments
- **indent-blankline.nvim** — visible indentation guides
- **which-key.nvim** — popup hints for pending key chords
- **todo-comments.nvim** — highlight TODO/FIXME/HACK
- **nvim-surround** — manipulate surrounding pairs
- **flash.nvim** — fast cursor jumps

To add or remove plugins, edit `~/.config/nvim/init.lua` then `:Lazy sync`.

---

## Customising

`init.lua` is heavily commented and self-documenting. Common tweaks:

```lua
-- Switch colorscheme
vim.cmd("colorscheme tokyonight")  -- need to add the plugin first

-- Add a leader binding
vim.keymap.set("n", "<leader>z", "<cmd>ZenMode<cr>", { desc = "Zen mode" })

-- Tabs vs spaces, indent width
opt.tabstop    = 2
opt.shiftwidth = 2
opt.expandtab  = true   -- false to use real tabs
```

Save the file, open nvim — lazy.nvim picks up plugin changes automatically;
keymaps and options take effect on the next launch (or `:source %`).

---

## Further reading

- [`/home/generic/.config/nvim/init.lua`](../config/nvim/init.lua) — every plugin and binding
- [`:help lazy.nvim`](https://github.com/folke/lazy.nvim) — plugin manager docs
- `:Telescope help_tags` — search nvim's built-in help
- [LearnVim Cheatsheet](https://learnvim.irian.to/) — for new users
