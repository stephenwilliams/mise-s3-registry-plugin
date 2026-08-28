--- Sets up environment variables for a tool
--- Documentation: https://mise.jdx.dev/backend-plugin-development.html#backendexecenv
--- @param ctx {install_path: string, tool: string, version: string} Context
--- @return {env_vars: table[]} Table containing list of environment variable definitions
function PLUGIN:BackendExecEnv(ctx)
    local file = require("file")
    local bin_path = file.join_path(ctx.install_path, "bin")

    return {
        env_vars = {
            { key = "PATH", value = bin_path },
        },
    }
end
