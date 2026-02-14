local lazypath = vim.fn.stdpath("data") .. "/lazy/lazy.nvim"
if not vim.loop.fs_stat(lazypath) then
  vim.fn.system({
    "git",
    "clone",
    "--filter=blob:none",
    "https://github.com/folke/lazy.nvim.git",
    "--branch=stable", -- latest stable release
    lazypath,
  })
end
vim.opt.rtp:prepend(lazypath)

require("lazy").setup({
  -- tokyonight.nvim configuration
  {
    "folke/tokyonight.nvim",
    lazy = false,
    priority = 1000,
    opts = {
      style = "night",
    },
  },
  -- nvim-tree.lua configuration
  {
    "nvim-tree/nvim-tree.lua",
    version = "*",
    lazy = false,
    dependencies = {
      "nvim-tree/nvim-web-devicons",
    },
    config = function()
      require("nvim-tree").setup({
        sort_by = "case_sensitive",
        view = {
          width = 30,
        },
        renderer = {
          group_empty = true,
        },
        filters = {
          dotfiles = true,
        },
      })
    end,
  },
})

-- Keybinding for NvimTreeToggle
vim.keymap.set('n', '<leader>e', '<cmd>NvimTreeToggle<CR>', { desc = 'Toggle NvimTree' })

vim.api.nvim_create_autocmd("FileType", {
  pattern = "python",
  callback = function()
    vim.api.nvim_buf_set_keymap(0, "n", "<F5>", ":w<CR>:vsplit | terminal python3 %<CR>", { noremap = true, silent = true })
  end,
})
vim.api.nvim_create_autocmd("FileType", {
  pattern = "javascript",
  callback = function()
    vim.api.nvim_buf_set_keymap(0, "n", "<F5>", ":w<CR>:vsplit | terminal node %<CR>", { noremap = true, silent = true })
  end,
})

-- Autocommand for Python linting and formatting with Ruff on save
vim.api.nvim_create_autocmd("BufWritePre", {
  pattern = "*.py",
  callback = function()
    -- Check if ruff is available
    if vim.fn.executable("ruff") == 0 then
      vim.notify("Ruff is not installed. Please install it for Python linting and formatting.", vim.log.levels.WARN)
      return
    end

    local file_path = vim.api.nvim_buf_get_name(0)
    if file_path == "" then
      return -- Don't process unnamed buffers
    end

    -- Run ruff format and ruff check --fix
    vim.cmd("silent !python3 -m ruff format --preview " .. file_path)
    vim.cmd("silent !python3 -m ruff check --fix --preview " .. file_path)
    
    -- Reload the buffer to reflect changes made by ruff
    vim.cmd("e!")
  end,
})

vim.cmd("colorscheme tokyonight-night")