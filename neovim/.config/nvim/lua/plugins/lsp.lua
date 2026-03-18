return {
  {
    "neovim/nvim-lspconfig",
    opts = {
      diagnostics = {
        virtual_text = false,
        signs = true,
        underlines = true,
        update_in_insert = false,
      },
      servers = {
        vtsls = {},
        ts_ls = { enabled = false },
      },
    },
  },
}
