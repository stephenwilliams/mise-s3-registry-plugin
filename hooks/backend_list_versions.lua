local lib = require("s3reg")

--- Lists available versions for a tool in this backend
--- Documentation: https://mise.jdx.dev/backend-plugin-development.html#backendlistversions
--- @param ctx {tool: string, options: table} Context
--- @return BackendListVersionsResult Ascending list of versions, with release dates when s3reg has them
function PLUGIN:BackendListVersions(ctx)
    local tool = ctx.tool

    if not tool or tool == "" then
        error("Tool name cannot be empty")
    end

    local http = require("http")
    local json = require("json")

    local base_url, token = lib.get_config(ctx)
    local api_url = base_url .. "/tools/" .. tool .. "/versions"

    local resp, err = http.get({
        url = api_url,
        headers = lib.auth_headers(token),
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

    local versions = lib.to_versions(data, lib.supports_release_dates())
    if #versions == 0 then
        error("No versions found for " .. tool)
    end

    return { versions = versions }
end
