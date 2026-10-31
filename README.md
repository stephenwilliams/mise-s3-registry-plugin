# mise-s3-registry-plugin

A [mise](https://mise.jdx.dev) backend plugin that installs versioned tool binaries served by
`s3reg`, a companion HTTP proxy that fronts a private S3 bucket. The backend name is `s3reg`, so
tools are referenced as `s3reg:<tool>` (e.g. `s3reg:mytool`).

## How it works

- `mise ls-remote s3reg:<tool>` lists versions by calling `GET {url}/tools/{tool}/versions` on the
  proxy. Each version carries its s3reg publish date, so mise's `minimum_release_age` applies.
- `mise install s3reg:<tool>@<version>` resolves the download via
  `GET {url}/tools/{tool}/versions/{version}/artifact?os=...&arch=...`, downloads the returned
  presigned archive URL, verifies its sha256, and extracts the archive's `bin/` directory into the
  install path.
- `mise use s3reg:<tool>@<version>` puts the tool's `bin/` on `PATH` when active.

## Setup

Install from GitHub:

```sh
mise plugin install s3reg https://github.com/stephenwilliams/mise-s3-registry-plugin
```

For local development, link a working copy instead:

```sh
mise plugin link s3reg /path/to/mise-s3-registry-plugin
```

### Configuration

The plugin needs to know where the s3reg proxy is, and optionally an auth token:

| Setting | Env var | Tool option |
| --- | --- | --- |
| Proxy base URL (required) | `S3REG_URL` | `url` |
| Bearer token (optional) | `S3REG_TOKEN` | `token` |

Environment variables apply to all `s3reg:*` tools. Tool options in `mise.toml` override the
environment variables for that tool only:

```toml
[tools]
"s3reg:mytool" = { version = "^1.2", url = "https://registry.example.com", token = "{{env.CI_S3REG_TOKEN}}" }
```

## Usage

```sh
mise use s3reg:mytool@^1.2      # latest version matching a semver range
mise use s3reg:mytool@latest    # latest available version
mise use s3reg:mytool@1.2.3     # exact version
mise ls-remote s3reg:mytool     # list all versions the registry has
```
