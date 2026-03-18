return {
  "NeogitOrg/neogit",
  dependencies = {
    "nvim-lua/plenary.nvim",
    "sindrets/diffview.nvim",
  },
  cmd = "Neogit",
  keys = {
    { "<leader>gs", "<cmd>Neogit<cr>", desc = "Neogit Status" },
  },
  opts = {
    integrations = {
      diffview = true,
    },
  },
}
