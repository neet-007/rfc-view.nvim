# `rfc-view.nvim`

Download, view, and search RFCs right from within Neovim.

---

## What is `rfc-view.nvim`?

`rfc-view.nvim` is a Neovim plugin that simplifies working with **RFC** documents. It allows you to download, view, and search RFCs, whether they are already cached locally or retrieved directly from the IETF RFC Editor website. All RFCs are opened as native Neovim buffers.

---

## Features
* Retrieve and display RFCs by name or number.
* Download specific RFCs.
* Download all RFCs from the IETF RFC Editor website at once.
* Cache RFCs as neovim buffers.
* Fuzzy search for downloaded RFCs.

---

## Installation

This plugin requires **Neovim 0.7.0 or a more recent version**.

You can install `rfc-view.nvim` using your preferred Neovim plugin manager.

### Using [`lazy.nvim`](https://github.com/folke/lazy.nvim)

```lua
{
  'neet-007/rfc-view.nvim',
  branch = 'master',
  build = 'cd go && go build main.go',
  config = function()
    require('rfcview').setup {
      -- Example configuration: automatically delete RFC buffers when closing
      delete_buffers_when_closing = true,
      -- You can also define your custom keymaps here:
      -- keys = {
      --   -- Your custom keymap overrides go here
      -- }
    }
  end,
  keys = {
    -- Global keymaps to open and close the plugin's main interface
    {
      '<leader>ro',
      function()
        require('rfcview').open_rfc()
      end,
      desc = '[R]FC [O]pen Main Window',
    },
    {
      '<leader>rc',
      function()
        require('rfcview').close_rfc()
      end,
      desc = '[R]FC [C]lose All Windows',
    },
  },
}
````

### Using [`packer.nvim`](https://github.com/wbthomason/packer.nvim)

```lua
use {
  'neet-007/rfc-view.nvim',
  branch = 'master',
  run = 'cd go && go build main.go',
  config = function()
    require('rfcview').setup {
      -- Example configuration: automatically delete RFC buffers when closing
      -- delete_buffers_when_closing = true,
      -- You can also define your custom keymaps here:
      -- keys = {
      --   -- Your custom keymap overrides go here
      -- }
    }
  end,
}

-- Remember to define your global keymaps separately if using Packer:
-- vim.keymap.set('n', '<leader>ro', function() require('rfcview').open_rfc() end, { desc = '[R]FC [O]pen Main Window' })
-- vim.keymap.set('n', '<leader>rc', function() require('rfcview').close_rfc() end, { desc = '[R]FC [C]lose All Windows' })
```

-----

## Getting Started

### Basic Usage

Once installed, you can open the main RFC viewer interface using your configured keymap (e.g., `<leader>ro`). From there, you can interact with the plugin to search, view, and manage RFCs.

-----

## Configuration

You can configure `rfc-view.nvim` by passing an options table to the `setup` function. It's **highly recommended** to call `setup` even if you're using default options, as it ensures the plugin initializes correctly.

Here are some common configuration options:

```lua
require('rfcview').setup({
  -- Whether to delete RFC buffers when the plugin's windows are closed.
  -- If set to `true`, RFC buffers are automatically cleaned up;
  -- otherwise, they remain open in the background. Defaults to `false`.
  delete_buffers_when_closing = false,

  -- Customize keymaps for actions within the plugin's RFC buffers and floating windows.
  -- These keymaps control viewing, listing, searching, and other functionalities.
  -- Uncomment and modify as needed to override default keymaps.
  keys = {
    -- view = "m",          -- Opens a detailed view of the current RFC
    -- list = "n",          -- Shows a list of all locally downloaded RFCs
    -- search = "b",        -- Activates the online RFC search interface
    -- search_header = "v", -- Focuses the input field in the search window
    -- select = "<CR>",     -- Confirms the current selection in a list
    -- add_to_view = "s",   -- Adds an online search result to your local RFC cache
    -- delete = "d",        -- Deletes the selected item from the list (and from disk if in local list view)
    -- refresh = "r",       -- Refreshes the current window's content
    -- hard_refresh = "R",  -- Performs a more aggressive refresh (e.g., re-fetches data from source)
    -- delete_all = "D",    -- Deletes all RFCs associated with the current view (e.g., all cached RFCs)
    -- view_list = "z",     -- Opens the list of cached RFCs
    -- next_search = "ns",  -- Navigates to the next page of search results
  },

  -- Whether to log non-error messages to the Neovim notification area.
  -- (defaults to true)
  log_non_errros = true,

  -- Directory to download RFCs to.
  -- (defaults to ~/.rfc_dirs_nvim)
  rfc_dir = "PATH"
})
```

-----

## Troubleshooting

  * **"RFC not found" or Network Errors:**
      * Ensure your internet connection is active.
      * Double-check that the RFC number you entered is valid.
      * Confirm that the `base_url` setting in your plugin configuration points to a correct and accessible RFC repository (e.g., `https://www.rfc-editor.org/rfc/rfc`).
  * **RFC content doesn't look formatted correctly:**
      * If you're using a custom `on_open_hook`, make sure it's correctly setting the buffer's filetype (e.g., to `rfc`).
      * You might need a syntax file for the `rfc` filetype. Consider installing a plugin that provides `rfc` syntax highlighting, or create a simple `syntax/rfc.vim` file in your Neovim configuration directory (e.g., `~/.config/nvim/after/syntax/`).
  * **Cache issues:**
      * If you suspect your locally cached RFCs are outdated or corrupted, you can manually clear the cache directory. The default location is `vim.fn.stdpath('data') .. '/rfcview_cache'` (or the path specified by your `cache_dir` option).

-----

## Contributing

For bug reports or feature requests, please visit the GitHub repository:
[https://github.com/neet-007/rfc-view.nvim](https://www.google.com/search?q=https://github.com/neet-007/rfc-view.nvim)

-----

## Acknowledgements
The fuzzy search logic implemented in rfc-view.nvim is a go port from telescope.nvim plugin.

----

## Changelog

  * **0.1.0** (2025-07-26)

      * Initial release.
      * Core functionality for RFC fetching, viewing, and basic management.
      * Introduced configuration options for `keys` and `delete_buffers_when_closing`.
