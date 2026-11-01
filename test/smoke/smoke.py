"""Real `mise install` of a fake tool through the plugin, without Docker.

Serves a fake s3reg API on 127.0.0.1 and runs mise in a throwaway home, so the
developer's mise is not touched. Runs the same on Linux, macOS and Windows.
"""

import hashlib
import http.server
import io
import json
import os
import platform
import re
import shutil
import subprocess
import sys
import tarfile
import tempfile
import threading
import urllib.parse
import zipfile

REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
WINDOWS = sys.platform == "win32"
GOOS = {"win32": "windows", "darwin": "darwin"}.get(sys.platform, "linux")
GOARCH = {"x86_64": "amd64", "amd64": "amd64", "arm64": "arm64", "aarch64": "arm64"}[platform.machine().lower()]
WRONG_SHA = "0" * 64


def build_archive(tool, version):
    """Returns (filename, bytes) of a goreleaser-style archive with bin/<tool>."""
    stem = f"{tool}_{version}_{GOOS}_{GOARCH}"
    buf = io.BytesIO()
    if WINDOWS:
        with zipfile.ZipFile(buf, "w") as z:
            z.writestr(f"bin/{tool}.cmd", f"@echo {tool} {version}\r\n")
        return stem + ".zip", buf.getvalue()
    script = f'#!/bin/sh\necho "{tool} {version}"\n'.encode()
    with tarfile.open(fileobj=buf, mode="w:gz") as t:
        info = tarfile.TarInfo(f"bin/{tool}")
        info.size = len(script)
        info.mode = 0o755
        t.addfile(info, io.BytesIO(script))
    return stem + ".tar.gz", buf.getvalue()


# badtool's artifact response carries a wrong sha256, for the negative case.
FILES = {}
TOOLS = {}
for name in ("mytool", "badtool"):
    filename, data = build_archive(name, "1.0.0")
    FILES[filename] = data
    TOOLS[name] = {
        "filename": filename,
        "sha256": WRONG_SHA if name == "badtool" else hashlib.sha256(data).hexdigest(),
    }


class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def send_body(self, status, body, content_type="application/json"):
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        url = urllib.parse.urlsplit(self.path)
        parts = url.path.strip("/").split("/")
        query = urllib.parse.parse_qs(url.query)
        if parts[0] == "files" and len(parts) == 2 and parts[1] in FILES:
            return self.send_body(200, FILES[parts[1]], "application/octet-stream")
        if len(parts) >= 3 and parts[0] == "tools" and parts[1] in TOOLS:
            tool = TOOLS[parts[1]]
            if parts[2:] == ["versions"]:
                body = {
                    "versions": ["1.0.0"],
                    "releases": [{"version": "1.0.0", "created_at": "2024-01-01T00:00:00Z"}],
                }
                return self.send_body(200, json.dumps(body).encode())
            if parts[2:] == ["versions", "1.0.0", "artifact"]:
                # A wrong os/arch means the plugin mapped RUNTIME badly.
                if query.get("os") != [GOOS] or query.get("arch") != [GOARCH]:
                    return self.send_body(404, b'{"error":"no artifact for os/arch"}')
                host = self.headers["Host"]
                body = {"url": f"http://{host}/files/{tool['filename']}", "sha256": tool["sha256"]}
                return self.send_body(200, json.dumps(body).encode())
        self.send_body(404, b'{"error":"not found"}')


def main():
    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    base_url = f"http://127.0.0.1:{server.server_address[1]}"

    mise = shutil.which("mise")
    if not mise:
        sys.exit("FAIL: mise is not on PATH")

    work = os.path.realpath(tempfile.mkdtemp(prefix="s3reg-smoke-"))
    # Drop the caller's mise state (incl. `mise run` vars) so only the throwaway home applies.
    env = {k: v for k, v in os.environ.items() if not k.upper().startswith(("MISE_", "__MISE_"))}
    for d in ("DATA", "CACHE", "CONFIG", "STATE"):
        path = os.path.join(work, d.lower())
        os.makedirs(path)
        env[f"MISE_{d}_DIR"] = path
    env.update({"MISE_YES": "1", "S3REG_URL": base_url, "MISE_CEILING_PATHS": work})
    cwd = os.path.join(work, "project")
    os.makedirs(cwd)

    def run(*args, expect_ok=True):
        print("$ mise " + " ".join(args), flush=True)
        p = subprocess.run([mise, *args], cwd=cwd, env=env, capture_output=True, encoding="utf-8", errors="replace")
        out = p.stdout + p.stderr
        print(out, end="" if out.endswith("\n") or not out else "\n", flush=True)
        if expect_ok and p.returncode != 0:
            sys.exit(f"FAIL: mise {' '.join(args)} exited {p.returncode}")
        if not expect_ok and p.returncode == 0:
            sys.exit(f"FAIL: mise {' '.join(args)} succeeded but should have failed")
        return out

    try:
        m = re.search(r"(\d+)\.(\d+)\.(\d+)", run("--version"))
        if not m:
            sys.exit("FAIL: could not parse the mise version")
        mise_version = tuple(map(int, m.groups()))
        run("plugin", "link", "--force", "s3reg", REPO)

        if "1.0.0" not in run("ls-remote", "s3reg:mytool"):
            sys.exit("FAIL: ls-remote did not list 1.0.0")
        # Older mise gets plain strings from the plugin's feature probe.
        if mise_version >= (2026, 10, 17) and "2024-01-01T00:00:00Z" not in run("ls-remote", "--json", "s3reg:mytool"):
            sys.exit("FAIL: ls-remote --json did not carry the release date")

        run("install", "s3reg:mytool@1.0.0")
        out = run("exec", "s3reg:mytool@1.0.0", "--", "mytool")
        if "mytool 1.0.0" not in out:
            sys.exit("FAIL: installed mytool did not print 'mytool 1.0.0'")

        out = run("install", "s3reg:badtool@1.0.0", expect_ok=False)
        if "sha256 mismatch" not in out:
            sys.exit("FAIL: bad checksum did not fail with 'sha256 mismatch'")
    finally:
        server.shutdown()
        shutil.rmtree(work, ignore_errors=True)

    print("PASS: smoke test")


if __name__ == "__main__":
    main()
