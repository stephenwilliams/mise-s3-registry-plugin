--- Resolves the s3reg base URL and optional bearer token, preferring per-tool
--- options in mise.toml over the S3REG_URL / S3REG_TOKEN environment variables.
local function get_config(ctx)
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

local function auth_headers(token)
    if token and token ~= "" then
        return { ["Authorization"] = "Bearer " .. token }
    end
    return nil
end

-- Maps RUNTIME.osType / RUNTIME.archType (and common aliases) to the
-- os/arch convention the s3reg proxy expects: darwin|linux|windows, amd64|arm64.
local function map_os(os_type)
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

local function map_arch(arch_type)
    local t = string.lower(arch_type or "")
    if t == "amd64" or t == "x86_64" or t == "x64" then
        return "amd64"
    elseif t == "arm64" or t == "aarch64" then
        return "arm64"
    end
    error("Unsupported architecture for s3reg: " .. tostring(arch_type))
end

-- Computes the sha256 of a file by shelling out, since vfox has no native
-- hashing module. Tries macOS/BSD `shasum` first, then GNU `sha256sum`.
local function sha256_file(cmd, path)
    local quoted = '"' .. path .. '"'

    -- cmd.exec yields in mise's async Lua, so it cannot be wrapped in pcall
    -- (that raises "attempt to yield across a C-call boundary"). Let the shell
    -- choose whichever hashing tool exists in a single invocation instead.
    local output = cmd.exec("shasum -a 256 " .. quoted .. " 2>/dev/null || sha256sum " .. quoted)
    if not output or output == "" then
        error("No sha256 utility (shasum or sha256sum) available to verify the download")
    end

    local hash = output:match("(%x+)")
    if not hash or #hash ~= 64 then
        error("Could not parse sha256 checksum from: " .. tostring(output))
    end
    return string.lower(hash)
end

-- Extracts a .tar.gz into install_path, preferring the native archiver
-- module and falling back to a shelled-out `tar` if it isn't available.
local function extract_archive(cmd, archive_path, install_path)
    cmd.exec('mkdir -p "' .. install_path .. '"')

    -- archiver.decompress and cmd.exec both yield, so neither can be wrapped in
    -- pcall (mise raises "attempt to yield across a C-call boundary"). Prefer the
    -- native archiver module and fall back to tar when it is unavailable.
    local has_archiver, archiver = pcall(require, "archiver")
    if has_archiver and archiver and archiver.decompress then
        archiver.decompress(archive_path, install_path)
        return
    end

    cmd.exec('tar -xzf "' .. archive_path .. '" -C "' .. install_path .. '"')
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

    local base_url, token = get_config(ctx)
    local os_name = map_os(RUNTIME.osType)
    local arch_name = map_arch(RUNTIME.archType)

    local artifact_url = base_url
        .. "/tools/"
        .. tool
        .. "/versions/"
        .. version
        .. "/artifact?os="
        .. os_name
        .. "&arch="
        .. arch_name

    local resp, err = http.get({ url = artifact_url, headers = auth_headers(token) })
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
    local filename = url_path:match("([^/]+)$") or (tool .. "-" .. version .. ".tar.gz")
    local archive_path = file.join_path(download_path, filename)

    -- http.download_file yields, so it must be called directly rather than via
    -- pcall (which raises "attempt to yield across a C-call boundary"); mise
    -- surfaces any download error itself.
    http.download_file({ url = artifact.url, headers = auth_headers(token) }, archive_path)

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

    extract_archive(cmd, archive_path, install_path)

    local bin_dir = file.join_path(install_path, "bin")
    if file.exists(bin_dir) then
        cmd.exec('chmod -R +x "' .. bin_dir .. '"')
    end

    return {}
end
