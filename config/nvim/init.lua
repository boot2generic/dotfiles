-- ============================================================
-- Neovim Configuration — Cyberpunk Neon
-- Deployed to: ~/.config/nvim/init.lua
--
-- Plugin manager: lazy.nvim (auto-bootstrapped on first run)
-- ============================================================

-- ── Bootstrap lazy.nvim ──────────────────────────────────────
local lazypath = vim.fn.stdpath("data") .. "/lazy/lazy.nvim"
if not vim.loop.fs_stat(lazypath) then
  vim.fn.system({
    "git", "clone", "--filter=blob:none",
    "https://github.com/folke/lazy.nvim.git",
    "--branch=stable",
    lazypath,
  })
end
vim.opt.rtp:prepend(lazypath)

-- ── Leader key (set before plugins load) ─────────────────────
vim.g.mapleader      = " "
vim.g.maplocalleader = " "

-- ── Options ──────────────────────────────────────────────────
local opt = vim.opt

opt.number         = true    -- line numbers
opt.relativenumber = true    -- relative line numbers
opt.cursorline     = true    -- highlight current line
opt.wrap           = false   -- no line wrap
opt.scrolloff      = 8       -- keep 8 lines above/below cursor
opt.sidescrolloff  = 8

opt.tabstop        = 4       -- tab = 4 spaces
opt.shiftwidth     = 4
opt.expandtab      = true    -- spaces instead of tabs
opt.smartindent    = true

opt.ignorecase     = true    -- case-insensitive search…
opt.smartcase      = true    -- …unless pattern has uppercase

opt.termguicolors  = true    -- 24-bit color
opt.signcolumn     = "yes"   -- always show sign column (no layout shift)
opt.splitbelow     = true    -- new horizontal split goes below
opt.splitright     = true    -- new vertical split goes right

opt.clipboard      = "unnamedplus"  -- use system clipboard
opt.undofile       = true           -- persistent undo history
opt.updatetime     = 250            -- faster CursorHold / gitsigns refresh
opt.timeoutlen     = 300            -- which-key popup delay

opt.list           = true           -- show whitespace characters
opt.listchars      = { tab = "→ ", trail = "·", nbsp = "␣" }

-- ── Plugins ──────────────────────────────────────────────────
require("lazy").setup({

  -- ── Colorscheme: Cyberdream ──────────────────────────────
  -- A neon/cyberpunk-inspired dark theme
  {
    "scottmckendry/cyberdream.nvim",
    lazy    = false,
    priority = 1000,
    config  = function()
      require("cyberdream").setup({
        transparent      = false,  -- set true if terminal has its own bg
        italic_comments  = true,
        hide_fillchars   = true,
        terminal_colors  = true,
        -- Override specific highlight colors to match our palette exactly
        overrides = function(c)
          return {
            Comment        = { fg = "#5555aa", italic = true },
            CursorLineNr   = { fg = "#00e5ff", bold   = true },
            LineNr         = { fg = "#2a2a4a" },
            StatusLine     = { bg = "#0d0d1a", fg = "#e2e2ff" },
          }
        end,
      })
      vim.cmd("colorscheme cyberdream")
    end,
  },

  -- ── Treesitter: syntax highlighting + indentation ────────
  -- tag = "v0.9.3" (Sep 2024) is the last release that still ships the
  -- `nvim-treesitter.configs` API.  The `main` branch is now the
  -- default and requires nvim 0.11+ AND deleted the configs module —
  -- Debian 13 ships nvim 0.10.4.  Pinning to a tag (vs the rolling
  -- `master` branch) means a compromised maintainer pushing to master
  -- can't ship arbitrary code through `:Lazy update`.
  {
    "nvim-treesitter/nvim-treesitter",
    tag    = "v0.9.3",
    build  = ":TSUpdate",
    config = function()
      require("nvim-treesitter.configs").setup({
        ensure_installed = {
          -- Languages requested by user
          "python", "c", "cpp", "yaml", "json", "rust",
          "lua", "php", "html",
          -- Additional useful parsers
          -- NOTE: typescript / javascript are deliberately omitted —
          -- the typescript parser source on nvim-treesitter master
          -- currently has a generation bug (`anon_syi_STAR` typo) that
          -- breaks compilation. Add them back once that's resolved.
          "bash", "markdown", "markdown_inline",
          "toml", "vim", "vimdoc",
        },
        auto_install  = true,
        highlight     = { enable = true, additional_vim_regex_highlighting = false },
        indent        = { enable = true },
        incremental_selection = {
          enable  = true,
          keymaps = {
            init_selection    = "<C-space>",
            node_incremental  = "<C-space>",
            scope_incremental = "<C-s>",
            node_decremental  = "<M-space>",
          },
        },
      })
    end,
  },

  -- ── Telescope: fuzzy finder ──────────────────────────────
  -- tag = "0.1.8" is the last frozen release on the 0.1.x line that
  -- supports nvim 0.9+ — pinning the tag (vs the moving 0.1.x branch)
  -- means upstream pushes don't auto-ship into our config.
  {
    "nvim-telescope/telescope.nvim",
    tag = "0.1.8",
    dependencies = {
      "nvim-lua/plenary.nvim",
      { "nvim-telescope/telescope-fzf-native.nvim", build = "make" },
    },
    config = function()
      local t = require("telescope")
      t.setup({
        defaults = {
          prompt_prefix   = "  ",
          selection_caret = " ",
          path_display    = { "smart" },
          layout_strategy = "horizontal",
          layout_config   = { preview_width = 0.55, height = 0.8 },
          -- Cyberpunk colors via highlight groups (inherits from cyberdream)
        },
        extensions = { fzf = {} },
      })
      t.load_extension("fzf")

      local b = require("telescope.builtin")
      vim.keymap.set("n", "<leader>ff", b.find_files,  { desc = "Find files" })
      vim.keymap.set("n", "<leader>fg", b.live_grep,   { desc = "Live grep" })
      vim.keymap.set("n", "<leader>fb", b.buffers,     { desc = "Buffers" })
      vim.keymap.set("n", "<leader>fh", b.help_tags,   { desc = "Help tags" })
      vim.keymap.set("n", "<leader>fr", b.oldfiles,    { desc = "Recent files" })
      vim.keymap.set("n", "<leader>fs", b.lsp_document_symbols, { desc = "Symbols" })
      vim.keymap.set("n", "<leader>/",  b.current_buffer_fuzzy_find, { desc = "Search buffer" })
    end,
  },

  -- ── File tree ────────────────────────────────────────────
  {
    "nvim-tree/nvim-tree.lua",
    dependencies = { "nvim-tree/nvim-web-devicons" },
    config = function()
      require("nvim-tree").setup({
        view     = { width = 30, side = "left" },
        renderer = {
          group_empty    = true,
          highlight_git  = true,
          icons = { show = { git = true, folder = true, file = true } },
        },
        filters  = { dotfiles = false },
        git      = { enable = true, ignore = false },
        actions  = { open_file = { quit_on_open = false } },
      })
      vim.keymap.set("n", "<leader>e",  ":NvimTreeToggle<CR>",  { desc = "Toggle tree" })
      vim.keymap.set("n", "<leader>ef", ":NvimTreeFindFile<CR>", { desc = "Find in tree" })
    end,
  },

  -- ── Statusline ───────────────────────────────────────────
  {
    "nvim-lualine/lualine.nvim",
    dependencies = { "nvim-tree/nvim-web-devicons" },
    config = function()
      -- Custom cyberpunk lualine theme
      local cp = {
        bg      = "#0d0d1a",
        surface = "#1a1a2e",
        fg      = "#e2e2ff",
        cyan    = "#00e5ff",
        magenta = "#ff00cc",
        green   = "#00ff41",
        red     = "#ff0055",
        overlay = "#5555aa",
      }
      local theme = {
        normal   = { a = { fg = cp.bg,  bg = cp.cyan,    gui = "bold" },
                     b = { fg = cp.fg,  bg = cp.surface },
                     c = { fg = cp.fg,  bg = cp.bg } },
        insert   = { a = { fg = cp.bg,  bg = cp.green,   gui = "bold" } },
        visual   = { a = { fg = cp.bg,  bg = cp.magenta, gui = "bold" } },
        replace  = { a = { fg = cp.bg,  bg = cp.red,     gui = "bold" } },
        inactive = { a = { fg = cp.overlay, bg = cp.bg },
                     c = { fg = cp.overlay, bg = cp.bg } },
      }
      require("lualine").setup({
        options = {
          theme                = theme,
          component_separators = { left = "│", right = "│" },
          section_separators   = { left = "",  right = "" },
          globalstatus         = true,
        },
        sections = {
          lualine_a = { "mode" },
          lualine_b = { "branch", "diff", "diagnostics" },
          lualine_c = { { "filename", path = 1 } },
          lualine_x = { "filetype" },
          lualine_y = { "progress" },
          lualine_z = { "location" },
        },
      })
    end,
  },

  -- ── Bufferline (tab bar) ─────────────────────────────────
  {
    "akinsho/bufferline.nvim",
    dependencies = "nvim-tree/nvim-web-devicons",
    config = function()
      require("bufferline").setup({
        options = {
          mode              = "buffers",
          diagnostics       = "nvim_lsp",
          separator_style   = "thin",
          show_close_icon   = false,
          show_buffer_close_icons = false,
        },
      })
    end,
  },

  -- ── LSP ──────────────────────────────────────────────────
  -- mason.nvim 2.x and mason-lspconfig.nvim 2.x both require nvim 0.11+
  -- (they call `vim.lsp.config.<name>.enable()`, a 0.11 API).  Pin to
  -- the last 1.x release of each so this works on Debian 13's nvim 0.10.4.
  -- nvim-lspconfig HEAD prints a deprecation banner on 0.10 but still
  -- works; pinning it to v1.8.0 silences the noise.
  {
    "neovim/nvim-lspconfig",
    tag = "v1.8.0",
    dependencies = {
      -- Mason: auto-install language servers
      { "williamboman/mason.nvim", tag = "v1.11.0", config = true },
      { "williamboman/mason-lspconfig.nvim", tag = "v1.32.0" },
      -- Progress notifications for LSP loading
      { "j-hui/fidget.nvim", opts = {} },
    },
    config = function()
      require("mason-lspconfig").setup({
        -- Servers auto-installed on first run
        ensure_installed = {
          "pyright",      -- Python
          "clangd",       -- C / C++
          "rust_analyzer",-- Rust
          "lua_ls",       -- Lua
          "intelephense", -- PHP
          "html",         -- HTML
          "jsonls",       -- JSON
          "yamlls",       -- YAML
        },
        automatic_installation = true,
      })

      local capabilities = require("cmp_nvim_lsp").default_capabilities()
      local lsp = require("lspconfig")

      local servers = {
        "pyright", "clangd", "rust_analyzer", "lua_ls",
        "intelephense", "html", "jsonls", "yamlls",
      }
      for _, name in ipairs(servers) do
        lsp[name].setup({ capabilities = capabilities })
      end

      -- Diagnostic display
      vim.diagnostic.config({
        virtual_text  = { prefix = "●" },
        severity_sort = true,
        float         = { border = "rounded", source = "always" },
      })

      -- LSP keymaps (active when LSP attaches)
      vim.api.nvim_create_autocmd("LspAttach", {
        callback = function(ev)
          local buf = ev.buf
          local map = function(keys, fn, desc)
            vim.keymap.set("n", keys, fn, { buffer = buf, desc = desc })
          end
          map("gd",         vim.lsp.buf.definition,      "Go to definition")
          map("gD",         vim.lsp.buf.declaration,     "Go to declaration")
          map("gr",         vim.lsp.buf.references,      "References")
          map("gI",         vim.lsp.buf.implementation,  "Implementation")
          map("K",          vim.lsp.buf.hover,           "Hover docs")
          map("<leader>rn", vim.lsp.buf.rename,          "Rename symbol")
          map("<leader>ca", vim.lsp.buf.code_action,     "Code action")
          map("<leader>ld", vim.diagnostic.open_float,   "Line diagnostics")
          map("[d",         vim.diagnostic.goto_prev,    "Prev diagnostic")
          map("]d",         vim.diagnostic.goto_next,    "Next diagnostic")
        end,
      })
    end,
  },

  -- ── Autocompletion ───────────────────────────────────────
  {
    "hrsh7th/nvim-cmp",
    dependencies = {
      "hrsh7th/cmp-nvim-lsp",
      "hrsh7th/cmp-buffer",
      "hrsh7th/cmp-path",
      "L3MON4D3/LuaSnip",
      "saadparwaiz1/cmp_luasnip",
      "rafamadriz/friendly-snippets",
    },
    config = function()
      local cmp     = require("cmp")
      local luasnip = require("luasnip")
      require("luasnip.loaders.from_vscode").lazy_load()

      cmp.setup({
        snippet = {
          expand = function(args) luasnip.lsp_expand(args.body) end,
        },
        mapping = cmp.mapping.preset.insert({
          ["<C-n>"]     = cmp.mapping.select_next_item(),
          ["<C-p>"]     = cmp.mapping.select_prev_item(),
          ["<C-d>"]     = cmp.mapping.scroll_docs(-4),
          ["<C-f>"]     = cmp.mapping.scroll_docs(4),
          ["<C-Space>"] = cmp.mapping.complete(),
          ["<C-e>"]     = cmp.mapping.abort(),
          ["<CR>"]      = cmp.mapping.confirm({ select = true }),
          ["<Tab>"]     = cmp.mapping(function(fallback)
            if cmp.visible() then
              cmp.select_next_item()
            elseif luasnip.expand_or_jumpable() then
              luasnip.expand_or_jump()
            else
              fallback()
            end
          end, { "i", "s" }),
          ["<S-Tab>"]   = cmp.mapping(function(fallback)
            if cmp.visible() then
              cmp.select_prev_item()
            elseif luasnip.jumpable(-1) then
              luasnip.jump(-1)
            else
              fallback()
            end
          end, { "i", "s" }),
        }),
        sources = cmp.config.sources({
          { name = "nvim_lsp" },
          { name = "luasnip" },
          { name = "path" },
          { name = "buffer", keyword_length = 3 },
        }),
        formatting = {
          format = function(_, item)
            local kind_icons = {
              Text = "", Method = "󰆧", Function = "󰊕", Constructor = "",
              Field = "󰇽", Variable = "󰂡", Class = "󰠱", Interface = "",
              Module = "", Property = "󰜢", Unit = "", Value = "󰎠",
              Enum = "", Keyword = "󰌋", Snippet = "", Color = "󰏘",
              File = "󰈙", Reference = "", Folder = "󰉋", EnumMember = "",
              Constant = "󰏿", Struct = "", Event = "", Operator = "󰆕",
              TypeParameter = "󰅲",
            }
            item.kind = string.format("%s %s", kind_icons[item.kind] or "", item.kind)
            return item
          end,
        },
        window = {
          completion    = cmp.config.window.bordered(),
          documentation = cmp.config.window.bordered(),
        },
      })
    end,
  },

  -- ── Git ──────────────────────────────────────────────────
  {
    "lewis6991/gitsigns.nvim",
    config = function()
      require("gitsigns").setup({
        signs = {
          add          = { text = "▎" },
          change       = { text = "▎" },
          delete       = { text = "" },
          topdelete    = { text = "" },
          changedelete = { text = "▎" },
          untracked    = { text = "▎" },
        },
        on_attach = function(buf)
          local gs = package.loaded.gitsigns
          vim.keymap.set("n", "]g", gs.next_hunk,  { buffer = buf, desc = "Next hunk" })
          vim.keymap.set("n", "[g", gs.prev_hunk,  { buffer = buf, desc = "Prev hunk" })
          vim.keymap.set("n", "<leader>gb", gs.blame_line, { buffer = buf, desc = "Git blame" })
          vim.keymap.set("n", "<leader>gd", gs.diffthis,  { buffer = buf, desc = "Git diff" })
        end,
      })
    end,
  },

  -- ── Autopairs ────────────────────────────────────────────
  { "windwp/nvim-autopairs", event = "InsertEnter", opts = {} },

  -- ── Comments ─────────────────────────────────────────────
  { "numToStr/Comment.nvim", opts = {} },

  -- ── Indent guides ────────────────────────────────────────
  {
    "lukas-reineke/indent-blankline.nvim",
    main = "ibl",
    opts = {
      indent = { char = "│", highlight = "IblIndent" },
      scope  = { enabled = true, highlight = "IblScope" },
    },
  },

  -- ── Which-key: keybinding popup ──────────────────────────
  {
    "folke/which-key.nvim",
    event  = "VeryLazy",
    config = function()
      require("which-key").setup({ preset = "modern" })
      -- Register group labels
      require("which-key").add({
        { "<leader>f", group = "Find (telescope)" },
        { "<leader>g", group = "Git" },
        { "<leader>l", group = "LSP" },
        { "<leader>e", group = "Explorer" },
      })
    end,
  },

  -- ── Todo comments ────────────────────────────────────────
  {
    "folke/todo-comments.nvim",
    dependencies = "nvim-lua/plenary.nvim",
    opts = { signs = true },
  },

  -- ── Surround ─────────────────────────────────────────────
  { "kylechui/nvim-surround", event = "VeryLazy", opts = {} },

  -- ── Flash: fast cursor navigation ────────────────────────
  {
    "folke/flash.nvim",
    event = "VeryLazy",
    opts  = {},
    keys  = {
      { "s",     function() require("flash").jump()              end, desc = "Flash jump",    mode = { "n", "x", "o" } },
      { "S",     function() require("flash").treesitter()        end, desc = "Flash treesitter", mode = { "n", "x", "o" } },
    },
  },

}, {
  -- lazy.nvim UI colors
  ui = {
    border = "rounded",
    icons  = { loaded = "●", not_loaded = "○" },
  },
})

-- ── Global keymaps ───────────────────────────────────────────
local map = function(mode, lhs, rhs, desc)
  vim.keymap.set(mode, lhs, rhs, { silent = true, desc = desc })
end

-- File operations
map("n", "<leader>w",  "<cmd>w<CR>",   "Save file")
map("n", "<leader>q",  "<cmd>q<CR>",   "Quit")
map("n", "<leader>Q",  "<cmd>qa!<CR>", "Quit all (no save)")

-- Buffer navigation
map("n", "<S-l>",      "<cmd>bnext<CR>",     "Next buffer")
map("n", "<S-h>",      "<cmd>bprevious<CR>", "Prev buffer")
map("n", "<leader>bd", "<cmd>bdelete<CR>",   "Delete buffer")

-- Window navigation (when not using vim-tmux-navigator)
map("n", "<C-h>", "<C-w>h", "Window left")
map("n", "<C-j>", "<C-w>j", "Window down")
map("n", "<C-k>", "<C-w>k", "Window up")
map("n", "<C-l>", "<C-w>l", "Window right")

-- Move lines in visual mode
map("v", "<A-j>", ":m '>+1<CR>gv=gv", "Move line down")
map("v", "<A-k>", ":m '<-2<CR>gv=gv", "Move line up")

-- Clear search highlight
map("n", "<Esc>", "<cmd>nohlsearch<CR>", "Clear highlight")

-- Quick access to config
map("n", "<leader>nc", "<cmd>e ~/.config/nvim/init.lua<CR>", "Edit nvim config")
