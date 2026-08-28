--- Resolves the s3reg base URL and optional bearer token, preferring per-tool
--- options in mise.toml over the S3REG_URL / S3REG_TOKEN environment variables.
local function get_config(ctx)
    local env = require("env")
    local options = ctx.options or {}

    local url = options.url
    if not url or url == "" then
        url = env.getenv("S3REG_URL")
    end
    if not url or url == "" then
        error("s3reg base URL is not set: pass it as the 'url' tool option or set S3REG_URL")
    end
    url = url:gsub("/+$", "")

    local token = options.token
    if not token or token == "" then
        token = env.getenv("S3REG_TOKEN")
    end

    return url, token
end

local function auth_headers(token)
    if token and token ~= "" then
        return { ["Authorization"] = "Bearer " .. token }
    end
    return nil
end

--- Lists available versions for a tool in this backend
--- Documentation: https://mise.jdx.dev/backend-plugin-development.html#backendlistversions
--- @param ctx {tool: string, options: table} Context
--- @return {versions: string[]} Table containing the ascending list of available versions
function PLUGIN:BackendListVersions(ctx)
    local tool = ctx.tool

    if not tool or tool == "" then
        error("Tool name cannot be empty")
    end

    local http = require("http")
    local json = require("json")

    local base_url, token = get_config(ctx)
    local api_url = base_url .. "/tools/" .. tool .. "/versions"

    local resp, err = http.get({
        url = api_url,
        headers = auth_headers(token),
    })

    if err then
        error("Failed to fetch versions for " .. tool .. ": " .. tostring(err))
    end

    if resp.status_code ~= 200 then
        error("s3reg returned status " .. tostring(resp.status_code) .. " listing versions for " .. tool)
    end

    local ok, data = pcall(json.decode, resp.body)
    if not ok or not data then
        error("Failed to parse versions response for " .. tool)
    end

    -- mise applies the user's semver range / @latest against this list, so
    -- it must be returned as-is rather than filtered or reordered here.
    local versions = data.versions or {}
    if #versions == 0 then
        error("No versions found for " .. tool)
    end

    return { versions = versions }
end
