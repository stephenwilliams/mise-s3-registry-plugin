-- Shared, side-effect-free helpers for the hooks. mise embeds Lua 5.1, so keep
-- this file 5.1-safe (no `//`, no `goto`, no integer ops).
local M = {}

--- Resolves the s3reg base URL and optional bearer token, preferring per-tool
--- options in mise.toml over the S3REG_URL / S3REG_TOKEN environment variables.
function M.get_config(ctx)
    local options = ctx.options or {}

    -- mise's env module only exposes setenv; reads go through standard Lua
    -- os.getenv (https://mise.jdx.dev/plugin-lua-modules.html).
    local url = options.url
    if not url or url == "" then
        url = os.getenv("S3REG_URL")
    end
    if not url or url == "" then
        error("s3reg base URL is not set: pass it as the 'url' tool option or set S3REG_URL")
    end
    url = url:gsub("/+$", "")

    local token = options.token
    if not token or token == "" then
        token = os.getenv("S3REG_TOKEN")
    end

    return url, token
end

function M.auth_headers(token)
    if token and token ~= "" then
        return { ["Authorization"] = "Bearer " .. token }
    end
    return nil
end

-- Maps RUNTIME.osType / RUNTIME.archType (and common aliases) to the
-- os/arch convention the s3reg proxy expects: darwin|linux|windows, amd64|arm64.
function M.map_os(os_type)
    local t = string.lower(os_type or "")
    if t == "darwin" or t == "macos" or t == "mac" then
        return "darwin"
    elseif t == "linux" then
        return "linux"
    elseif t == "windows" or t == "win" then
        return "windows"
    end
    error("Unsupported operating system for s3reg: " .. tostring(os_type))
end

function M.map_arch(arch_type)
    local t = string.lower(arch_type or "")
    if t == "amd64" or t == "x86_64" or t == "x64" then
        return "amd64"
    elseif t == "arm64" or t == "aarch64" then
        return "arm64"
    end
    error("Unsupported architecture for s3reg: " .. tostring(arch_type))
end

function M.is_windows(os_type)
    local t = string.lower(os_type or "")
    return t == "windows" or t == "win"
end

-- mise runs cmd.exec through `cmd /C` on Windows and `sh -c` elsewhere, and has
-- no hash module, so each OS gets its own checksum tool.
function M.sha256_command(os_type, path)
    local quoted = '"' .. path .. '"'
    if M.is_windows(os_type) then
        return "certutil -hashfile " .. quoted .. " SHA256"
    end
    return "shasum -a 256 " .. quoted .. " 2>/dev/null || sha256sum " .. quoted
end

-- Accepts shasum/sha256sum (`<hex>  <path>`) and certutil output, whose hash
-- sits on its own line, space-separated on older Windows. Header text such as
-- "SHA256 hash of" holds short hex runs, so only a 64-char token counts.
function M.parse_sha256(output)
    for line in tostring(output or ""):gmatch("[^\r\n]+") do
        local compact = line:gsub("%s", "")
        if #compact == 64 and compact:match("^%x+$") then
            return string.lower(compact)
        end
        -- GNU sha256sum prefixes `\` when the path holds a backslash.
        local first = line:match("^%s*\\?(%x+)")
        if first and #first == 64 then
            return string.lower(first)
        end
    end
    error("Could not parse sha256 checksum from: " .. tostring(output))
end

-- mise before 2026.10.15 accepts only version strings from BackendListVersions,
-- and exposes no version to Lua. RUNTIME.cacheDirPath arrived in 2026.10.17, so
-- it serves as the feature probe. RUNTIME may raise on unknown fields.
function M.supports_release_dates()
    local ok, value = pcall(function()
        return RUNTIME.cacheDirPath
    end)
    return ok and value ~= nil
end

-- mise applies the user's semver range / @latest against this list, so it is
-- returned as-is rather than filtered or reordered. `releases` adds publish
-- dates for minimum_release_age; servers older than that field send only
-- `versions`.
function M.to_versions(data, with_dates)
    if type(data.releases) ~= "table" then
        return data.versions or {}
    end
    local versions = {}
    for _, r in ipairs(data.releases) do
        if with_dates and type(r.created_at) == "string" and r.created_at ~= "" then
            table.insert(versions, { version = r.version, created_at = r.created_at })
        else
            table.insert(versions, r.version)
        end
    end
    return versions
end

return M
