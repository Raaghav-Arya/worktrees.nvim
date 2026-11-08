--- @class GitModule
local M = {}

local function run(args, cwd)
    local command = { "git", "-C", cwd or vim.fn.getcwd() }
    vim.list_extend(command, args)
    return vim.system(command, { text = true }):wait()
end

local function absolute(path, cwd)
    if not path or path == "" then return nil end
    local is_absolute = path:match("^[/\\]") or path:match("^%a:[/\\]")
    if not is_absolute then path = vim.fs.joinpath(cwd or vim.fn.getcwd(), path) end
    return vim.fs.normalize(vim.fn.fnamemodify(path, ":p"))
end

M.get_repo_root = function(cwd)
    local result = run({ "rev-parse", "--show-toplevel" }, cwd)
    if result.code ~= 0 or result.stdout == "" then return nil end
    return absolute(vim.trim(result.stdout), cwd)
end

--- Get the parent of the git common dir, used as the plugin's default base.
M.get_git_common_dir = function(cwd)
    local result = run({ "rev-parse", "--path-format=absolute", "--git-common-dir" }, cwd)
    if result.code ~= 0 or result.stdout == "" then return nil end
    return vim.fs.normalize(vim.fn.fnamemodify(vim.trim(result.stdout), ":h"))
end

M.get_worktree_root = M.get_repo_root

--- Worktree info: { path, branch, name, head, detached, bare, locked, prunable }
M.get_worktrees = function(cwd)
    local root = M.get_repo_root(cwd)
    if not root then return nil end
    local result = run({ "worktree", "list", "--porcelain" }, root)
    if result.code ~= 0 then return nil end

    local worktrees, current = {}, nil
    local function finish()
        if current and current.path and not current.bare then
            worktrees[current.path] = current
        end
        current = nil
    end
    for line in ((result.stdout or "") .. "\n"):gmatch("([^\n]*)\n") do
        if line == "" then
            finish()
        else
            current = current or {}
            local key, value = line:match("^(%S+)%s?(.*)$")
            if key == "worktree" then
                current.path = absolute(value, root)
            elseif key == "branch" then
                current.branch = value
                current.name = value:gsub("^refs/heads/", "")
            elseif key == "HEAD" then
                current.head = value
            elseif key == "bare" or key == "detached" or key == "locked" or key == "prunable" then
                current[key] = true
            end
        end
    end
    finish()
    return worktrees
end

return M
