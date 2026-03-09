return {
  {
    "neovim/nvim-lspconfig",
    opts = {
      servers = {
        marksman = {
          mason = false,
          autostart = false,
        },
      },
    },
  },
}
