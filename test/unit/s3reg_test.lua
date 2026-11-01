-- Plain-assert unit tests for lib/s3reg.lua. Run from the repo root:
--   lua test/unit/s3reg_test.lua
package.path = "lib/?.lua;" .. package.path
local lib = require("s3reg")

local HEX = "9f86d081884c7d659a2feaa0c55ad015a3bf4f1b2b0b822cd15d6c15b0f00a08"
local passed, failed = 0, 0

local function test(name, fn)
    local ok, err = pcall(fn)
    if ok then
        passed = passed + 1
    else
        failed = failed + 1
        print("FAIL " .. name .. ": " .. tostring(err))
    end
end

local function eq(actual, expected, label)
    if actual ~= expected then
        error((label or "value") .. ": expected " .. tostring(expected) .. ", got " .. tostring(actual), 2)
    end
end

local function raises(fn, pattern)
    local ok, err = pcall(fn)
    if ok then
        error("expected an error", 2)
    end
    if pattern and not tostring(err):find(pattern, 1, true) then
        error("error " .. tostring(err) .. " does not contain " .. pattern, 2)
    end
end

-- parse_sha256 ------------------------------------------------------------

test("parse_sha256 shasum output", function()
    eq(lib.parse_sha256(HEX .. "  /tmp/dl/mytool_1.0.0_darwin_arm64.tar.gz\n"), HEX)
end)

test("parse_sha256 sha256sum output with escaped path", function()
    eq(lib.parse_sha256("\\" .. HEX .. "  /tmp/a\\\\b.tar.gz\n"), HEX)
end)

test("parse_sha256 certutil output", function()
    local out = "SHA256 hash of C:\\Users\\me\\dl\\mytool_1.0.0_windows_amd64.zip:\r\n"
        .. string.upper(HEX)
        .. "\r\nCertUtil: -hashfile command completed successfully.\r\n"
    eq(lib.parse_sha256(out), HEX)
end)

test("parse_sha256 spaced certutil output", function()
    local spaced = HEX:gsub("(%x%x)", "%1 ")
    local out = "SHA256 hash of file C:\\dl\\x.zip:\r\n"
        .. spaced
        .. "\r\nCertUtil: -hashfile command completed successfully.\r\n"
    eq(lib.parse_sha256(out), HEX)
end)

test("parse_sha256 ignores a 64-hex directory in the certutil header", function()
    local out = "SHA256 hash of C:\\" .. string.rep("a", 64) .. "\\x.zip:\r\n" .. HEX .. "\r\n"
    eq(lib.parse_sha256(out), HEX)
end)

test("parse_sha256 rejects garbage", function()
    raises(function()
        lib.parse_sha256("CertUtil: The system cannot find the file specified.")
    end, "Could not parse sha256")
    raises(function()
        lib.parse_sha256("")
    end, "Could not parse sha256")
    raises(function()
        lib.parse_sha256(nil)
    end, "Could not parse sha256")
end)

-- sha256_command ----------------------------------------------------------

test("sha256_command windows uses certutil with a quoted path", function()
    eq(lib.sha256_command("windows", "C:\\dl dir\\x.zip"), 'certutil -hashfile "C:\\dl dir\\x.zip" SHA256')
end)

test("sha256_command unix does not use certutil", function()
    for _, os_type in ipairs({ "linux", "darwin" }) do
        local c = lib.sha256_command(os_type, "/tmp/x.tar.gz")
        eq(c:find("certutil", 1, true), nil, os_type)
        eq(c:find('"/tmp/x.tar.gz"', 1, true) ~= nil, true, os_type .. " quotes path")
    end
end)

-- map_os / map_arch / is_windows -------------------------------------------

test("map_os aliases", function()
    eq(lib.map_os("darwin"), "darwin")
    eq(lib.map_os("macOS"), "darwin")
    eq(lib.map_os("mac"), "darwin")
    eq(lib.map_os("Linux"), "linux")
    eq(lib.map_os("windows"), "windows")
    eq(lib.map_os("win"), "windows")
    raises(function()
        lib.map_os("plan9")
    end, "Unsupported operating system")
    raises(function()
        lib.map_os(nil)
    end, "Unsupported operating system")
end)

test("map_arch aliases", function()
    eq(lib.map_arch("amd64"), "amd64")
    eq(lib.map_arch("x86_64"), "amd64")
    eq(lib.map_arch("x64"), "amd64")
    eq(lib.map_arch("arm64"), "arm64")
    eq(lib.map_arch("AARCH64"), "arm64")
    raises(function()
        lib.map_arch("riscv64")
    end, "Unsupported architecture")
end)

test("is_windows", function()
    eq(lib.is_windows("windows"), true)
    eq(lib.is_windows("Win"), true)
    eq(lib.is_windows("linux"), false)
    eq(lib.is_windows(nil), false)
end)

-- to_versions -------------------------------------------------------------

local releases = {
    releases = {
        { version = "1.0.0", created_at = "2024-01-01T00:00:00Z" },
        { version = "1.1.0", created_at = "" },
        { version = "1.2.0" },
    },
}

test("to_versions with dates", function()
    local v = lib.to_versions(releases, true)
    eq(#v, 3, "count")
    eq(v[1].version, "1.0.0")
    eq(v[1].created_at, "2024-01-01T00:00:00Z")
    eq(v[2], "1.1.0")
    eq(v[3], "1.2.0")
end)

test("to_versions without dates gives strings", function()
    local v = lib.to_versions(releases, false)
    eq(#v, 3, "count")
    for i, want in ipairs({ "1.0.0", "1.1.0", "1.2.0" }) do
        eq(v[i], want, "entry " .. i)
    end
end)

test("to_versions legacy versions-only payload", function()
    local v = lib.to_versions({ versions = { "0.1.0", "0.2.0" } }, true)
    eq(#v, 2, "count")
    eq(v[1], "0.1.0")
    eq(v[2], "0.2.0")
    eq(#lib.to_versions({}, true), 0, "empty payload")
end)

-- supports_release_dates --------------------------------------------------

local saved_runtime = RUNTIME

test("supports_release_dates with cacheDirPath", function()
    RUNTIME = { osType = "linux", cacheDirPath = "/tmp/cache" }
    eq(lib.supports_release_dates(), true)
end)

test("supports_release_dates without cacheDirPath", function()
    RUNTIME = { osType = "linux" }
    eq(lib.supports_release_dates(), false)
end)

test("supports_release_dates when indexing raises", function()
    RUNTIME = setmetatable({}, {
        __index = function(_, k)
            error("unknown field " .. k)
        end,
    })
    eq(lib.supports_release_dates(), false)
end)

RUNTIME = saved_runtime

print(string.format("%d passed, %d failed", passed, failed))
if failed > 0 then
    os.exit(1)
end
