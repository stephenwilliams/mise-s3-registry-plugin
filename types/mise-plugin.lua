--- LuaCATS type definitions for mise vfox plugins
--- These annotations provide IDE support via lua-language-server.
--- See https://luals.github.io/wiki/annotations/

------------------------------------------------------------------------
-- Globals
------------------------------------------------------------------------

---@class Runtime
---@field osType string Operating system type (e.g. "linux", "darwin", "windows")
---@field archType string Architecture type (e.g. "amd64", "arm64")
---@field version string Runtime version
---@field pluginDirPath string Path to the plugin directory
---@field cacheDirPath? string Plugin cache directory (mise 2026.10.17+)
RUNTIME = {}

--- @deprecated Use RUNTIME.osType instead
---@type string
OS_TYPE = ""

--- @deprecated Use RUNTIME.archType instead
---@type string
ARCH_TYPE = ""

------------------------------------------------------------------------
-- PLUGIN table & hook method signatures
------------------------------------------------------------------------

---@class BackendListVersionsCtx
---@field tool string Tool name
---@field options table Plugin/tool options from mise.toml

---@class BackendVersionEntry
---@field version string Version string
---@field created_at? string RFC 3339 release date, for minimum_release_age

---@class BackendListVersionsResult
---@field versions (string|BackendVersionEntry)[] List of available versions, oldest first

---@class BackendInstallCtx
---@field tool string Tool name
---@field version string Version to install
---@field install_path string Path where the tool should be installed
---@field download_path string Path where the downloaded archive should be written
---@field options table Plugin/tool options from mise.toml

---@class BackendInstallResult

---@class EnvKey
---@field key string Environment variable name
---@field value string Environment variable value

---@class BackendExecEnvCtx
---@field tool string Tool name
---@field version string Installed version
---@field install_path string Installation path
---@field options table Plugin/tool options from mise.toml

---@class BackendExecEnvResult
---@field env_vars EnvKey[] Environment variables to set

---@class Plugin
---@field name string Plugin name
---@field BackendListVersions? fun(self: Plugin, ctx: BackendListVersionsCtx): BackendListVersionsResult
---@field BackendInstall? fun(self: Plugin, ctx: BackendInstallCtx): BackendInstallResult
---@field BackendExecEnv? fun(self: Plugin, ctx: BackendExecEnvCtx): BackendExecEnvResult
PLUGIN = {}

------------------------------------------------------------------------
-- Built-in modules (available via require)
------------------------------------------------------------------------

-- http module --------------------------------------------------------

---@class HttpRequestOpts
---@field url string Request URL
---@field headers? table<string, string> HTTP headers

---@class HttpResponse
---@field status_code integer HTTP status code
---@field headers table<string, string> Response headers
---@field body string Response body (only for get, not head)

---@class http
---@field get fun(opts: HttpRequestOpts): HttpResponse, string? Send a GET request
---@field head fun(opts: HttpRequestOpts): HttpResponse, string? Send a HEAD request (no body)
---@field download_file fun(opts: HttpRequestOpts, path: string) Download a file to disk
local http = {}

-- json module --------------------------------------------------------

---@class json
---@field encode fun(value: any): string Encode a value as JSON
---@field decode fun(str: string): any Decode a JSON string
local json = {}

-- file module --------------------------------------------------------

---@class file
---@field read fun(path: string): string Read file contents
---@field exists fun(path: string): boolean Check if a file exists
---@field symlink fun(src: string, dst: string) Create a symbolic link
---@field join_path fun(...: string): string Join path components
local file = {}

-- cmd module ---------------------------------------------------------

---@class CmdExecOpts
---@field cwd? string Working directory
---@field env? table<string, string> Environment variables
---@field timeout? integer Timeout in milliseconds

---@class cmd
---@field exec fun(command: string, opts?: CmdExecOpts): string Execute a shell command
local cmd = {}

-- env module ---------------------------------------------------------

-- mise's env module only writes; read env vars with standard Lua os.getenv.
-- https://mise.jdx.dev/plugin-lua-modules.html
---@class env
---@field setenv fun(key: string, val: string) Set an environment variable
local env = {}

-- archiver module ----------------------------------------------------

---@class archiver
---@field decompress fun(archive: string, dest: string) Decompress an archive (.zip, .tar.gz, .tar.xz, .tar.bz2)
local archiver = {}

return nil
