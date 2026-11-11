# Nebulium runtime releases

Install bundles for the Nebulium runtime, the server side of Nebulium that runs on your own Linux machine.

Nebulium 运行端的安装包。运行端装在你自己的 Linux 服务器上。

## Install · 安装

On a Linux server with systemd (Debian 12/13 or Ubuntu 22.04/24.04, x86_64 or arm64), as root:

```sh
curl -fsSL https://raw.githubusercontent.com/Layla-NL/nebulium-releases/main/install.sh | sudo bash -s -- --domain home.example.com
```

Replace `--domain home.example.com` with `--tailscale`, `--lan` or `--public-url https://…` to match how your phone
reaches the server. When it finishes it prints a pairing code, a pairing link and the home's key fingerprint.

把 `--domain home.example.com` 换成 `--tailscale`、`--lan` 或 `--public-url https://…`，按手机怎么连到这台服务器来选。
装完会打印配对码、配对链接和家的公钥指纹。

Remove it with `sudo bash install.sh --uninstall` (add `--purge` to delete its data too).

## What is here · 这里有什么

- `install.sh`: the installer. It downloads the bundle for this machine, checks its SHA-256 against `latest.txt`, and
  installs it as a system service under its own user.
- `latest.txt`: the current version and the SHA-256 of each bundle.
- Releases: one `nebulium-runtime-<version>-<platform>.tar.gz` per platform, each holding the server, its dependencies
  and Node.js.

The runtime is built on OpenMausBot (Apache License 2.0); see `LICENSE` and `NOTICE`.
