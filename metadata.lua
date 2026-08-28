-- metadata.lua
-- Backend plugin metadata and configuration
-- Documentation: https://mise.jdx.dev/backend-plugin-development.html

PLUGIN = { -- luacheck: ignore
    name = "s3reg",

    version = "0.1.0",

    description = "A mise backend plugin that installs versioned tool binaries from an s3reg registry proxy backed by a private S3 bucket.",

    author = "me@stephenwilliams.io",

    homepage = "https://github.com/stephenwilliams/mise-s3-registry-plugin",

    license = "MIT",

    notes = {
        "Set S3REG_URL to the base URL of your s3reg proxy (e.g. https://registry.example.com).",
        "Set S3REG_TOKEN if the proxy requires a bearer token.",
        "Both can be overridden per-tool via the 'url' and 'token' options in mise.toml.",
    },
}
