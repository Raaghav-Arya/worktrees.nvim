--- *worktrees* Git worktree management
--- *Worktrees*
---
--- MIT License
---
--- ==============================================================================
---
--- Features:
--- - Interactive creation, deletion, and switching of git worktrees
--- - Configurable base path and path templates for new worktrees
--- - Automatic file correspondence when switching between worktrees

--- @class GitModule
local git = require("worktrees.git")

-- Module definition ==========================================================
local Worktrees = {}
local H = {}

--- Module setup
---
---@param config table|nil Module config table.
---
---@usage >lua
---   require('worktrees').setup() -- use default config
---   -- OR
---   require('worktrees').setup({}) -- replace {} with your config table
--- <
Worktrees.setup = function(config)
    -- Setup config
    config = H.setup_config(config)

    -- Apply config
    H.apply_config(config)
end

--- Module config
Worktrees.config = {
    -- Path relative to git common dir where worktrees will be created
    -- Examples: ".." (parent dir), "../.worktrees" (special dir), "." (same dir)
    base_path = "..",

    -- Path template for new worktrees, when one isn't manually provided
    -- Use {branch} as placeholder for branch name, or provide a function(branch) -> path
    path_template = "{branch}",

    -- "current" preserves the original behavior; "tab" reuses a matching
    -- tab or creates a new tab with tab-local cwd set to the worktree.
    open_mode = "current",
    -- Optional adapter: function(items, on_choice), where items have label,
    -- path, branch, and create fields. Defaults to vim.ui.select.
    picker = nil,

    -- Lifecycle hooks (optional)
    -- on_create: called with (path) after a worktree is successfully created
    on_create = nil,
    -- on_delete: called with (path) after a worktree is successfully deleted
    on_delete = nil,
    -- on_switch: called with (from_path, to_path) after a successful worktree switch
    on_switch = nil,
    -- on_tab_open: called with context after opening a new Neovim tab.
    on_tab_open = nil,

    -- Command names for interactive functions
    commands = {
        create = "WorktreeCreate",
        delete = "WorktreeDelete",
        switch = "WorktreeSwitch",
        browse = "WorktreeBrowse",
    },

    -- Optional key mappings
    mappings = {
        create = nil, -- e.g., "<leader>wc"
        delete = nil, -- e.g., "<leader>wd"
        switch = nil, -- e.g., "<leader>ws"
    },
}

-- Module functionality =======================================================

--- Utility functions for programmatic worktree management
Worktrees.utils = {}

--- Switch to a worktree by path
---@param path string path to the worktree
---@param change_root boolean whether to change the root directory (default: true)
---@return boolean success Indicates if the switch was successful
Worktrees.utils.switch_worktree = function(path, change_root)
    if change_root == nil then change_root = true end

    local invoking_cwd = vim.fn.getcwd()
    local worktree_root = git.get_worktree_root(invoking_cwd)
    local from_path = worktree_root and vim.fs.normalize(worktree_root) or nil
    local worktrees = git.get_worktrees(invoking_cwd)
    if not worktrees or vim.tbl_count(worktrees) == 0 then
        H.notify("No git worktrees found in this repo", vim.log.levels.ERROR)
        return false
    end

    if not path or path == "" then
        H.notify("Worktree path is required", vim.log.levels.ERROR)
        return false
    end

    -- Normalize the path for consistency
    local normalized_path = vim.fs.normalize(path)

    -- Check if the path exists
    local stat = vim.uv.fs_stat(normalized_path)
    if not stat or stat.type ~= "directory" then
        H.notify("Worktree path does not exist: " .. path, vim.log.levels.ERROR)
        return false
    end

    -- Try to find branch name for the worktree
    local target_worktree = worktrees[normalized_path]
    if not target_worktree then
        H.notify("Path is not a worktree in the current repository: " .. path, vim.log.levels.ERROR)
        return false
    end

    local branch_name = target_worktree.name or (target_worktree.detached and "detached" or vim.fn.fnamemodify(path, ":t"))

    if Worktrees.config.open_mode == "tab" then
        local context = H.open_worktree_tab(target_worktree, from_path, vim.api.nvim_get_current_tabpage())
        if not context then return false end
        H.dispatch_activation(context)
        return true
    end

    -- Check if the current file exists in the selected worktree
    local corresponding_file = H.get_current_file_in_other_worktree(path)

    -- Change directory to the new worktree
    if change_root then
        vim.cmd.cd(vim.fn.fnameescape(path))
    end


    if corresponding_file then
        -- Switch to the corresponding file in the other worktree
        vim.cmd.edit(vim.fn.fnameescape(corresponding_file))
        H.notify("Switched to worktree: " .. branch_name, vim.log.levels.INFO)
    else
        -- Just change directory to the worktree
        vim.cmd.edit(".")
        H.notify(
            "Switched to worktree: " .. branch_name .. " (file not found)",
            vim.log.levels.INFO
        )
    end
    vim.cmd.clearjumps()

    if Worktrees.config.on_switch then
        vim.schedule(function() H.call_hook("on_switch", from_path, normalized_path) end)
    end

    return true
end

--- Create a new worktree
---@param path string|nil path to the new worktree (optional)
---@param branch string name of the branch to use in the new worktree
---@param switch? boolean should the plugin switch to the newly created worktree
---@return string|nil path of the new worktree if it was created successfully
Worktrees.utils.create_worktree = function(path, branch, switch)
    if not branch or branch == "" then
        H.notify("Branch name is required", vim.log.levels.ERROR)
        return nil
    end

    local invoking_cwd = vim.fn.getcwd()
    local repo_root = git.get_repo_root(invoking_cwd)
    if not repo_root then
        H.notify("Not in a git repository", vim.log.levels.ERROR)
        return nil
    end
    local base_path = H.get_base_path(invoking_cwd)
    if not base_path then return nil end

    -- Trim whitespace from path if it exists
    path = path and vim.trim(path)

    -- Determine the worktree path
    local worktree_path
    if path and path ~= "" then
        -- User provided a specific path
        if vim.fn.fnamemodify(path, ":p") == path then
            -- Absolute path
            worktree_path = vim.fs.normalize(path)
        else
            -- Relative path (to base_path)
            worktree_path = vim.fs.normalize(
                vim.fn.resolve(vim.fs.joinpath(base_path, path))
            )
        end
    else
        -- Use the template to create a path
        local path_from_template
        if vim.is_callable(Worktrees.config.path_template) then
            path_from_template = Worktrees.config.path_template(branch)
        else
            path_from_template = Worktrees.config.path_template:gsub("{branch}", branch)
        end
        worktree_path = vim.fs.normalize(
            vim.fn.resolve(vim.fs.joinpath(base_path, path_from_template))
        )
    end

    -- Create a branch when needed; scope both checks and worktree creation to
    -- the repository captured before any prompt or picker changed context.
    local branch_exists = vim.system({ "git", "-C", repo_root, "show-ref", "--verify", "--quiet", "refs/heads/" .. branch }):wait().code == 0
    local command = { "git", "-C", repo_root, "worktree", "add" }
    if not branch_exists then vim.list_extend(command, { "-b", branch }) end
    table.insert(command, worktree_path)
    if branch_exists then table.insert(command, branch) end
    local result = vim.system(command, { text = true }):wait()

    if result.code ~= 0 then
        H.notify(
            "Failed to create worktree: " .. (result.stderr or ""),
            vim.log.levels.ERROR
        )
        return nil
    end

    H.notify(
        "Created worktree: " .. branch .. " at " .. worktree_path,
        vim.log.levels.INFO
    )

    vim.schedule(function()
        H.call_hook("on_create", worktree_path)
        H.emit("WorktreeCreated", { path = worktree_path, branch = branch, created = true })
    end)

    -- Check if this is the first worktree, if so switch to it
    local worktrees = git.get_worktrees(repo_root)
    if (worktrees and vim.tbl_count(worktrees) == 1) or switch == true then
        vim.schedule(function()
            Worktrees.utils.switch_worktree(worktree_path,true)
        end)
    end

    return worktree_path
end

--- Delete a worktree by path
---@param path string path to the worktree
---@return boolean success Indicates if the deletion was successful
Worktrees.utils.delete_worktree = function(path)
    if not path or path == "" then
        H.notify("Worktree path is required", vim.log.levels.ERROR)
        return false
    end

    local result = vim.system({
        "git",
        "worktree",
        "remove",
        path,
        "--force",
    }, { text = true }):wait()

    if result.code ~= 0 then
        H.notify(
            "Failed to delete worktree: " .. (result.stderr or ""),
            vim.log.levels.ERROR
        )
        return false
    end

    H.notify("Deleted worktree at: " .. path, vim.log.levels.INFO)

    if Worktrees.config.on_delete then vim.schedule(function() H.call_hook("on_delete", path) end) end

    return true
end

-- Interactive UI functions ===================================================

-- Run extension code defensively: user callbacks must not undo successful Git
-- operations or leave a tab switch half-finished.
H.call_hook = function(name, ...)
    local callback = Worktrees.config[name]
    if callback then
        local ok, err = pcall(callback, ...)
        if not ok then H.notify("worktrees.nvim " .. name .. " hook failed: " .. tostring(err), vim.log.levels.ERROR) end
    end
end

H.emit = function(event, context)
    local ok, err = pcall(vim.api.nvim_exec_autocmds, "User", {
        pattern = event,
        modeline = false,
        data = context,
    })
    if not ok then H.notify("worktrees.nvim " .. event .. " event failed: " .. tostring(err), vim.log.levels.ERROR) end
end

H.open_worktree_tab = function(worktree, from_path, from_tab)
    local target = vim.fs.normalize(worktree.path)
    local stat = vim.uv.fs_stat(target)
    if not stat or stat.type ~= "directory" then
        H.notify("Worktree path does not exist: " .. target, vim.log.levels.ERROR)
        return nil
    end

    local target_tab, reused
    for _, tab in ipairs(vim.api.nvim_list_tabpages()) do
        local tabnr = vim.api.nvim_tabpage_get_number(tab)
        local cwd = vim.fn.getcwd(-1, tabnr)
        local ok, root = pcall(git.get_worktree_root, cwd)
        if ok and root and vim.fs.normalize(root) == target then
            target_tab, reused = tab, true
            break
        end
    end

    if target_tab then
        vim.api.nvim_set_current_tabpage(target_tab)
    else
        vim.cmd.tabnew()
        vim.cmd("tcd " .. vim.fn.fnameescape(target))
        target_tab, reused = vim.api.nvim_get_current_tabpage(), false
    end
    local label = worktree.name or ((worktree.detached and "detached-" or "") .. vim.fn.fnamemodify(target, ":t"))
    if not vim.t.name or vim.t.name == "" then vim.t.name = label end

    return {
        path = target,
        branch = worktree.name,
        tab = target_tab,
        from_tab = from_tab or vim.api.nvim_get_current_tabpage(),
        from_path = from_path,
        created = false,
        reused = reused,
    }
end

H.dispatch_activation = function(context)
    H.call_hook("on_switch", context.from_path, context.path)
    H.emit("WorktreeActivated", context)
    if not context.reused then
        H.call_hook("on_tab_open", context)
        H.emit("WorktreeTabOpened", context)
    end
end

--- Open a Snacks/custom picker with all worktrees and a create-by-path item.
Worktrees.browse = function()
    local invoking_cwd = vim.fn.getcwd()
    local invoking_tab = vim.api.nvim_get_current_tabpage()
    local root = git.get_repo_root(invoking_cwd)
    if not root then
        H.notify("Not in a git repository", vim.log.levels.ERROR)
        return
    end
    local worktrees = git.get_worktrees(root)
    if not worktrees then
        H.notify("Failed to list git worktrees", vim.log.levels.ERROR)
        return
    end

    local items = {}
    for _, wt in pairs(worktrees) do
        local branch = wt.name or (wt.detached and "(detached HEAD)") or "(unknown branch)"
        table.insert(items, {
            label = string.format("%s  %s", wt.path, branch),
            path = wt.path,
            branch = wt.name,
            worktree = wt,
        })
    end
    table.sort(items, function(a, b) return a.path < b.path end)
    table.insert(items, { label = "+ Create/open worktree by path…", create = true })

    local function activate_worktree(worktree, from_path, from_tab, created)
        if Worktrees.config.open_mode == "current" then
            local ok = Worktrees.utils.switch_worktree(worktree.path, true)
            if ok then
                H.emit("WorktreeActivated", {
                    path = worktree.path,
                    branch = worktree.name,
                    tab = vim.api.nvim_get_current_tabpage(),
                    from_tab = from_tab,
                    created = created or false,
                    reused = false,
                })
            end
            return
        end
        local context = H.open_worktree_tab(worktree, from_path, from_tab)
        if context then
            context.created = created or false
            H.dispatch_activation(context)
        end
    end

    local function activate(item)
        if not item then return end
        if item.create then
            vim.ui.input({ prompt = "Worktree path: " }, function(input)
                if not input or vim.trim(input) == "" then return end
                input = vim.fn.expand(vim.trim(input))
                local is_absolute = input:match("^[/\\]") or input:match("^%a:[/\\]")
                local path = is_absolute and vim.fs.normalize(input)
                    or vim.fs.normalize(vim.fn.fnamemodify(vim.fs.joinpath(invoking_cwd, input), ":p"))
                local existing = worktrees[path]
                if existing then
                    activate_worktree(existing, git.get_worktree_root(invoking_cwd), invoking_tab)
                    return
                end
                if vim.uv.fs_stat(path) then
                    H.notify("Path exists but is not a registered worktree: " .. path, vim.log.levels.ERROR)
                    return
                end
                local result = vim.system({ "git", "-C", root, "worktree", "add", path }, { text = true }):wait()
                -- Git normally derives a new branch from the directory name.
                -- A valid filesystem path can contain characters (notably
                -- spaces) that are not allowed in branch names; retry detached
                -- in that specific case rather than rejecting the path.
                if result.code ~= 0 and (result.stderr or ""):match("not a valid branch name") then
                    result = vim.system({ "git", "-C", root, "worktree", "add", "--detach", path }, { text = true }):wait()
                end
                if result.code ~= 0 then
                    H.notify("Failed to create worktree: " .. (result.stderr or "unknown Git error"), vim.log.levels.ERROR)
                    return
                end
                local updated = git.get_worktrees(root)
                local created = updated and updated[path]
                if not created then
                    H.notify("Git created the worktree but it could not be discovered: " .. path, vim.log.levels.ERROR)
                    return
                end
                local context = {
                    path = path,
                    branch = created.name,
                    from_path = git.get_worktree_root(invoking_cwd),
                    from_tab = invoking_tab,
                    created = true,
                    reused = false,
                }
                H.call_hook("on_create", path)
                H.emit("WorktreeCreated", context)
                activate_worktree(created, context.from_path, invoking_tab, true)
            end)
            return
        end
        activate_worktree(item.worktree, git.get_worktree_root(invoking_cwd), invoking_tab)
    end

    if Worktrees.config.picker then
        Worktrees.config.picker(items, activate)
    else
        vim.ui.select(items, {
            prompt = "Select worktree",
            format_item = function(item) return item.label end,
        }, function(_, index)
            activate(index and items[index])
        end)
    end
end

--- Interactive worktree creation
Worktrees.create = function()
    vim.ui.input({
        prompt = "Enter branch name for new worktree: ",
    }, function(branch)
        if not branch or branch == "" then
            H.notify("Worktree creation cancelled", vim.log.levels.INFO)
            return
        end

        vim.ui.input({
            prompt = "Enter path for new worktree (empty for template): ",
        }, function(path)
            if path == nil then -- User cancelled
                H.notify("Worktree creation cancelled", vim.log.levels.INFO)
                return
            end

            local created_path = Worktrees.utils.create_worktree(path, branch)
            -- Check if creation succeeded
            if not created_path then return end

            -- Use a select prompt for confirmation instead of text input
            vim.ui.select({ "No", "Yes" }, {
                prompt = "Switch to the new worktree?",
            }, function(confirm)
                if confirm == "Yes" then
                    Worktrees.utils.switch_worktree(created_path,true)
                end
            end)
        end)
    end)
end

--- Interactive worktree deletion
Worktrees.delete = function()
    local worktrees = git.get_worktrees()
    if not worktrees or vim.tbl_count(worktrees) == 0 then
        H.notify("No worktrees found", vim.log.levels.WARN)
        return
    end

    ---@type Worktree[]
    local worktree_list = vim.tbl_values(worktrees)

    -- Format worktrees for selection
    local items = {}
    for _, wt in ipairs(worktree_list) do
        local branch_info = wt.name or vim.fn.fnamemodify(wt.path, ":t")
        local label = branch_info .. " (" .. wt.path .. ")"
        table.insert(items, label)
    end

    vim.ui.select(items, {
        prompt = "Select worktree to delete:",
    }, function(choice, idx)
        if not choice then
            H.notify("Worktree deletion cancelled", vim.log.levels.INFO)
            return
        end

        local selected_worktree = worktree_list[idx]

        -- Use a select prompt for confirmation
        vim.ui.select({ "No", "Yes" }, {
            prompt = "Confirm deletion of worktree at '" .. selected_worktree.path .. "':",
        }, function(confirm)
            if confirm == "Yes" then
                Worktrees.utils.delete_worktree(selected_worktree.path)
            else
                H.notify("Worktree deletion cancelled", vim.log.levels.INFO)
            end
        end)
    end)
end

--- Interactive worktree switching
---@param change_root boolean whether to change the root directory (default: true)
Worktrees.switch = function(change_root)
    if change_root == nil then change_root = true end

    local worktrees = git.get_worktrees()
    if not worktrees or vim.tbl_count(worktrees) == 0 then
        H.notify("No worktrees found", vim.log.levels.WARN)
        return
    end

    -- Get current worktree path if it exists
    local current_worktree_path = vim.fs.normalize(git.get_worktree_root() or "")

    local other_worktrees = vim.tbl_filter(function(wt)
        return wt.path ~= current_worktree_path
    end, worktrees)

    if #other_worktrees == 0 then
        H.notify(
            "No other worktrees available to switch to",
            vim.log.levels.WARN
        )
        return
    end

    -- Format worktrees for selection
    local items = {}
    for _, wt in ipairs(other_worktrees) do
        local branch_info = wt.name or vim.fn.fnamemodify(wt.path, ":t")
        local label = branch_info .. " (" .. wt.path .. ")"
        table.insert(items, label)
    end

    vim.ui.select(items, {
        prompt = "Select worktree to switch to:",
    }, function(choice, idx)
        if not choice then
            H.notify("Worktree switch cancelled", vim.log.levels.INFO)
            return
        end

        local selected_worktree = other_worktrees[idx]
        Worktrees.utils.switch_worktree(selected_worktree.path,change_root)
    end)
end

-- Helper data ================================================================
-- Module default config
H.default_config = vim.deepcopy(Worktrees.config)

-- Helper functionality =======================================================
-- Settings -------------------------------------------------------------------
H.setup_config = function(config)
    H.check_type("config", config, "table", true)
    config = vim.tbl_deep_extend("force", vim.deepcopy(H.default_config), config or {})

    H.check_type("base_path", config.base_path, "string")
    if type(config.path_template) ~= "string" and not vim.is_callable(config.path_template) then
        H.error("`path_template` should be a string or callable, not " .. type(config.path_template))
    end
    H.check_type("commands", config.commands, "table")
    H.check_type("mappings", config.mappings, "table")

    -- Validate commands
    H.check_type("commands.create", config.commands.create, "string")
    H.check_type("commands.delete", config.commands.delete, "string")
    H.check_type("commands.switch", config.commands.switch, "string")
    H.check_type("commands.browse", config.commands.browse, "string")
    H.check_type("open_mode", config.open_mode, "string")
    if config.open_mode ~= "current" and config.open_mode ~= "tab" then
        H.error("`open_mode` should be 'current' or 'tab'")
    end
    H.check_type("picker", config.picker, "callable", true)

    -- Validate mappings (can be nil)
    H.check_type("mappings.create", config.mappings.create, "string", true)
    H.check_type("mappings.delete", config.mappings.delete, "string", true)
    H.check_type("mappings.switch", config.mappings.switch, "string", true)

    -- Validate callbacks (callable or nil)
    H.check_type("on_create", config.on_create, "callable", true)
    H.check_type("on_delete", config.on_delete, "callable", true)
    H.check_type("on_switch", config.on_switch, "callable", true)
    H.check_type("on_tab_open", config.on_tab_open, "callable", true)

    return config
end

H.apply_config = function(config)
    Worktrees.config = config

    -- Create user commands
    H.create_commands(config.commands)

    -- Set up optional key mappings
    H.create_mappings(config.mappings)
end

H.create_commands = function(commands)
    local command_defs = {
        {
            commands.create,
            Worktrees.create,
            "Create a git worktree (interactive)",
        },
        {
            commands.delete,
            Worktrees.delete,
            "Delete a git worktree (interactive)",
        },
        {
            commands.switch,
            Worktrees.switch,
            "Switch to a git worktree (interactive)",
        },
        {
            commands.browse,
            Worktrees.browse,
            "Browse and open git worktrees",
        },
    }

    for _, cmd in ipairs(command_defs) do
        vim.api.nvim_create_user_command(cmd[1], cmd[2], { desc = cmd[3] })
    end
end

H.create_mappings = function(mappings)
    local mapping_defs = {
        {
            mappings.create,
            Worktrees.create,
            "Create git worktree",
        },
        {
            mappings.delete,
            Worktrees.delete,
            "Delete git worktree",
        },
        {
            mappings.switch,
            Worktrees.switch,
            "Switch git worktree",
        },
    }

    for _, mapping in ipairs(mapping_defs) do
        if mapping[1] then
            vim.keymap.set("n", mapping[1], mapping[2], {
                noremap = true,
                silent = true,
                desc = mapping[3],
            })
        end
    end
end

-- Utilities ------------------------------------------------------------------
H.error = function(msg)
    error("(worktrees) " .. msg, 0)
end

H.check_type = function(name, val, ref, allow_nil)
    if
        type(val) == ref
        or (ref == "callable" and vim.is_callable(val))
        or (allow_nil and val == nil)
    then
        return
    end
    H.error(
        string.format("`%s` should be %s, not %s", name, ref, type(val))
    )
end

H.notify = function(msg, level)
    vim.notify(msg, level or vim.log.levels.INFO)
end

-- Calculate base path for new worktrees based on config
H.get_base_path = function(cwd)
    local common_dir = git.get_git_common_dir(cwd)

    if not common_dir then
        vim.notify("Not in a git repository", vim.log.levels.ERROR)
        return nil
    end

    return vim.fs.normalize(vim.fs.joinpath(common_dir, Worktrees.config.base_path))
end

-- Get the corresponding file path in another worktree
H.get_current_file_in_other_worktree = function(target_worktree_path)
    local current_file = vim.fn.expand("%:p")
    if current_file == "" then
        return nil
    end

    local current_worktree = git.get_worktree_root()
    if not current_worktree then
        return nil
    end

    -- Normalize paths to avoid format differences
    current_worktree = vim.fs.normalize(current_worktree)
    current_file = vim.fs.normalize(current_file)
    target_worktree_path = vim.fs.normalize(target_worktree_path)

    -- Check if the current file is within the current worktree
    local is_descendant = vim.startswith(current_file, current_worktree)
    if not is_descendant then
        return nil
    end

    -- Get relative path from worktree to current file
    local relative_path = vim.fs.relpath(current_worktree, current_file)

    -- Create corresponding path in target worktree
    local target_file = vim.fs.joinpath(target_worktree_path, relative_path)

    -- Check if the file exists in the target worktree
    local stat = vim.uv.fs_stat(target_file)
    if stat then
        return target_file
    else
        return nil
    end
end

return Worktrees
