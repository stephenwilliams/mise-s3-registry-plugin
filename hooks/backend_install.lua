local lib = require("s3reg")

-- cmd.exec yields in mise's async Lua, so it cannot be wrapped in pcall (that
-- raises "attempt to yield across a C-call boundary").
local function sha256_file(cmd, path)
    return lib.parse_sha256(cmd.exec(lib.sha256_command(RUNTIME.osType, path)))
end

--- Installs a specific version of a tool
--- Documentation: https://mise.jdx.dev/backend-plugin-development.html#backendinstall
--- @param ctx {tool: string, version: string, install_path: string, download_path: string, options: table} Context
--- @return table Empty table on success
function PLUGIN:BackendInstall(ctx)
    local tool = ctx.tool
    local version = ctx.version
    local install_path = ctx.install_path
    local download_path = ctx.download_path

    if not tool or tool == "" then
        error("Tool name cannot be empty")
    end
    if not version or version == "" then
        error("Version cannot be empty")
    end
    if not install_path or install_path == "" then
        error("Install path cannot be empty")
    end
    if not download_path or download_path == "" then
        error("Download path cannot be empty")
    end

    local http = require("http")
    local json = require("json")
    local file = require("file")
    local cmd = require("cmd")

    local base_url, token = lib.get_config(ctx)
    local os_name = lib.map_os(RUNTIME.osType)
    local arch_name = lib.map_arch(RUNTIME.archType)
    local windows = lib.is_windows(RUNTIME.osType)

    local artifact_url = base_url
        .. "/tools/"
        .. tool
        .. "/versions/"
        .. version
        .. "/artifact?os="
        .. os_name
        .. "&arch="
        .. arch_name

    local resp, err = http.get({ url = artifact_url, headers = lib.auth_headers(token) })
    if err then
        error("Failed to resolve artifact for " .. tool .. "@" .. version .. ": " .. tostring(err))
    end
    if resp.status_code ~= 200 then
        error(
            "s3reg returned status "
                .. tostring(resp.status_code)
                .. " resolving artifact for "
                .. tool
                .. "@"
                .. version
        )
    end

    local ok, artifact = pcall(json.decode, resp.body)
    if not ok or not artifact or not artifact.url then
        error("Failed to parse artifact response for " .. tool .. "@" .. version)
    end

    -- mise hands download_path to the plugin as a directory. Download the
    -- archive into it under the artifact's real filename (taken from the URL
    -- path) so the extractor can detect the format from the extension.
    local url_path = artifact.url:match("^[^?]+") or artifact.url
    local fallback_ext = windows and ".zip" or ".tar.gz"
    local filename = url_path:match("([^/]+)$") or (tool .. "-" .. version .. fallback_ext)
    local archive_path = file.join_path(download_path, filename)

    -- http.download_file yields, so it must be called directly rather than via
    -- pcall (which raises "attempt to yield across a C-call boundary"); mise
    -- surfaces any download error itself.
    http.download_file({ url = artifact.url, headers = lib.auth_headers(token) }, archive_path)

    -- Verify integrity BEFORE extracting anything from the downloaded archive.
    if not artifact.sha256 or artifact.sha256 == "" then
        error("s3reg artifact response for " .. tool .. "@" .. version .. " did not include a sha256 checksum")
    end
    local actual_sha256 = sha256_file(cmd, archive_path)
    if actual_sha256 ~= string.lower(artifact.sha256) then
        error(
            "sha256 mismatch for "
                .. tool
                .. "@"
                .. version
                .. ": expected "
                .. artifact.sha256
                .. " but got "
                .. actual_sha256
        )
    end

    -- decompress creates install_path and picks the format from the extension.
    require("archiver").decompress(archive_path, install_path)

    -- tar and zip usually keep unix modes; this covers archives built without them.
    local bin_dir = file.join_path(install_path, "bin")
    if not windows and file.exists(bin_dir) then
        cmd.exec('chmod -R +x "' .. bin_dir .. '"')
    end

    return {}
end
