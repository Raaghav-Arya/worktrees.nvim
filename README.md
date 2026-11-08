# worktrees.nvim

A simple and configurable Neovim plugin for working with Git worktrees.

`worktrees.nvim` makes it easy to create, delete, and switch between Git worktrees directly from Neovim. 
When switching between worktrees, it will try to open the same file in the target worktree if it exists.

> [!NOTE]
> This project is feature complete for its intended small scope of managing Git worktrees (create, delete, switch). While actively maintained (don't be scared if there are no commits for a long time), new features will be limited to improvements of existing functionality and simple additions within this scope. Pull requests are welcome as long as they align with these goals.

## Demo

https://github.com/user-attachments/assets/9873ec7e-4660-4301-9618-82054af3eb1f

## Features

- Create new Git worktrees with branch creation
- Delete worktrees with confirmation
- Switch between worktrees while preserving your place in files
- Lifecycle hooks for create, delete, and switch events
- Configurable picker, tab reuse, and worktree lifecycle events
- Customizable commands and keymaps
- Works with any Git worktree structure

## Requirements

- Neovim 0.11.0 or higher
- Git installed and accessible in path
- A Git repository

## Installation

## Setup with [lazy.nvim](https://github.com/folke/lazy.nvim)

```lua
{
   "Raaghav-Arya/worktrees.nvim",
   event = "VeryLazy",
   opts = {
          -- Specify where to create worktrees relative to git common dir
          -- The common dir is the .git dir in a normal repo or the root dir of a bare repo
          base_path = "..",  -- Parent directory of common dir
          
          -- Template for worktree folder names (string or function(branch) -> path)
          -- This is only used if you don't specify the folder name when creating the worktree
           path_template = "{branch}",  -- Default: use branch name

           -- Preserve current-buffer behavior or reuse/open a tab
           open_mode = "current", -- "current" | "tab"

           -- Optional picker adapter: function(items, on_choice)
           picker = function(items, on_choice)
             vim.ui.select(items, {
               prompt = "Select worktree",
               format_item = function(item) return item.label end,
             }, function(_, index)
               on_choice(index and items[index])
             end)
           end,
          
          -- Command names (optional)
          commands = {
            create = "WorktreeCreate",
            delete = "WorktreeDelete",
            switch = "WorktreeSwitch",
          },
          
          -- Key mappings for interactive UI (optional)
          mappings = {
            create = "<leader>wtc",
            delete = "<leader>wtd",
            switch = "<leader>wts",
          },

          -- Lifecycle hooks (optional)
          on_create = function(path) end,
          on_delete = function(path) end,
           on_switch = function(from_path, to_path) end,
           on_tab_open = function(context) end,
    }
}
```

### Configuration Options

| Option | Description | Default |
|--------|-------------|---------|
| `base_path` | Path relative to git common directory where worktrees will be created | `".."` (parent directory) |
| `path_template` | Template for worktree folder names (`{branch}` is replaced with branch name), or a `function(branch)` returning a path | `"{branch}"` |
| `open_mode` | Switch in the current editor (`"current"`) or reuse/open a Neovim tab (`"tab"`) | `"current"` |
| `picker` | Optional `function(items, on_choice)` UI adapter; defaults to `vim.ui.select` | `nil` |
| `commands.create` | Command name for creating worktrees | `"WorktreeCreate"` |
| `commands.delete` | Command name for deleting worktrees | `"WorktreeDelete"` |
| `commands.switch` | Command name for switching worktrees | `"WorktreeSwitch"` |
| `mappings.create` | Key mapping for creating worktrees | `nil` (not set) |
| `mappings.delete` | Key mapping for deleting worktrees | `nil` (not set) |
| `mappings.switch` | Key mapping for switching worktrees | `nil` (not set) |
| `on_create` | Callback `function(path)` called after a worktree is created | `nil` |
| `on_delete` | Callback `function(path)` called after a worktree is deleted | `nil` |
| `on_switch` | Callback `function(from_path, to_path)` called after switching worktrees | `nil` |
| `on_tab_open` | Callback `function(context)` called only after creating a new tab in tab mode | `nil` |

### Common Worktree Configurations

#### Worktrees in parent directory (standard)

```lua
require('worktrees').setup({
  base_path = ".."  -- worktrees at the parent directory of the .git directory
})
```

#### Worktrees inside the repository

```lua
require('worktrees').setup({
  base_path = "."  -- worktrees inside same directory as .git
})
```

#### Worktrees outside the repository

```lua
require('worktrees').setup({
  base_path = "../.."  -- worktrees outside the repo 
})
```

## Usage

### Commands (Interactive UI)

| Command | Description |
|---------|-------------|
| `:WorktreeCreate` | Interactively create a new worktree |
| `:WorktreeDelete` | Delete a worktree with an interactive selector |
| `:WorktreeSwitch` | Switch to another worktree with an interactive selector |
| `:WorktreeBrowse` | Browse every worktree and create/open by path |

### Functions (Interactive UI)

```lua
-- Create a worktree interactively
require('worktrees').create()

-- Switch to a worktree interactively
require('worktrees').switch()

-- Browse all worktrees and create/open one by path
require('worktrees').browse()

-- Delete a worktree interactively
require('worktrees').delete()

```

### Functions (API)

```lua
-- Create a new worktree
---@param path string path to the new worktree
---@param branch string name of the branch to use in the new worktree
---@param switch? boolean should the plugin switch to the newly created worktree
---@return string|nil # path of the new worktree if it was created successfully
require('worktrees').utils.create_worktree("path/to/worktree", "feature-branch", true)

-- Switch to a worktree by path
---@param path string path to the worktree
---@return boolean # Indicates if the switch was successfull
require('worktrees').utils.switch_worktree("path/to/worktree")

-- Delete a worktree by path
---@param path string path to the worktree
---@return boolean # Indicates if the deletion was successfull
require('worktrees').utils.delete_worktree("path/to/worktree")

```

## How It Works

1. **Create:** When creating a worktree, you'll be prompted for a branch name and an optional path. The path is relative to the `base_path` specified in your config.

2. **Delete:** Shows a selection menu of available worktrees. After selecting one, you'll be asked to confirm deletion.

3. **Switch:** Shows a selection menu of other worktrees. After selecting one, the plugin will:
   - If the current file exists in the target worktree: Switch to that file
    - Otherwise: Change to the worktree directory and open the startup buffer

### Browse, tab mode, picker adapters, and hooks

`browse()` lists every non-bare worktree, including the current one, and a create/open-by-path entry. Relative paths are resolved against the cwd where browsing began. Registered paths activate the existing worktree; existing unrelated directories are left untouched. Git normally derives a branch from the directory name; if that name is not a valid Git branch (for example, it contains spaces), the plugin retries as a detached worktree.

With `open_mode = "tab"`, activation selects an existing tab whose Git worktree root matches the target, or creates a new tab with tab-local cwd set to the worktree. New tabs are labeled through `vim.t.name`. The default `"current"` preserves existing current-buffer switching behavior.

The optional picker adapter receives `{ label, path, branch, worktree }` records (the create item has `create = true`) and an `on_choice(item)` callback. A Snacks adapter can retain the original item on the picker result:

```lua
picker = function(items, on_choice)
  local picker_items = vim.tbl_map(function(item)
    return { text = item.label, worktree_item = item }
  end, items)
  Snacks.picker({
    items = picker_items,
    format = "text",
    preview = "none",
    confirm = function(picker, item)
      picker:close()
      vim.schedule(function() on_choice(item and item.worktree_item) end)
    end,
  })
end
```

`on_create(path)` runs after successful creation; `on_switch(from_path, to_path)` runs after activation; `on_tab_open(context)` runs only for a newly created tab, after it is current and its cwd is set. The corresponding `User` events are `WorktreeCreated`, `WorktreeActivated`, and `WorktreeTabOpened`; their `data` is a context table containing `path`, `branch`, `tab`, `from_tab`, `created`, and `reused`. Callback errors are reported without undoing successful Git or tab operations.

Optional Sidekick example (not enabled by default):

```lua
on_tab_open = function(context)
  require("sidekick.cli").toggle({ name = "opencode", focus = true })
end
```

Sidekick terminals have only one visible window; avoid moving a session across worktree tabs automatically.

## License

MIT
