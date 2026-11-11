#!/usr/bin/env bash
# Installs or upgrades a Nebulium home on a Linux server, as a system service under its own user.
#
#   sudo bash install.sh [--domain home.example.com | --tailscale | --lan | --public-url https://… | --local-only] [--port N]
#   sudo bash install.sh --uninstall [--purge]
#
# With no bundle it downloads the current release (nebulium.ai, GitHub as the fallback). It also runs from an unpacked
# bundle (it sits beside app/ and node/), or with one given:
#   sudo bash install.sh --bundle /path/or/https-url/nebulium-runtime-…-linux-x64.tar.gz [--sha256 HEX]
#
# What it does, and nothing else: installs bubblewrap and socat (the sandbox bots run in), makes a system user, puts
# the bundle in /opt/<name>, keeps data in /var/lib/<name>, writes one systemd unit, starts it, and prints a pairing
# code. It never touches another service, a firewall, or ports it was not given, and it refuses a name whose user,
# folders or unit already exist and are not its own. Running it again upgrades in place: the data and the options
# given before are kept, and a version that does not start is replaced by the one that ran.
set -euo pipefail

NAME=nebulium
PORT=""
REACH=""
REACH_ARG=""
REACH_SET=0
BUNDLE="${NEB_BUNDLE_URL:-}"
SHA256=""
SANDBOX=""
UNINSTALL=0
PURGE=0
PAIR=1

# Where a release comes from when no bundle is given. NEB_* variables point an installation at a mirror.
RELEASE_LIST="${NEB_RELEASE_LIST:-https://nebulium.ai/runtime/latest.txt}"
RELEASE_LIST_FALLBACK="${NEB_RELEASE_LIST_FALLBACK:-https://raw.githubusercontent.com/Layla-NL/nebulium-releases/main/latest.txt}"
DOWNLOAD_BASE="${NEB_DOWNLOAD_BASE:-https://dl.nebulium.ai/runtime}"
DOWNLOAD_FALLBACK="${NEB_DOWNLOAD_FALLBACK:-https://github.com/Layla-NL/nebulium-releases/releases/download}"

die() { echo "install.sh: $*" >&2; exit 1; }
say() { echo "==> $*"; }

set_reach() { [ "$REACH_SET" -eq 0 ] || die "choose one of --domain, --tailscale, --lan, --public-url, --local-only"; REACH_SET=1; REACH="$1"; REACH_ARG="${2:-}"; }

while [ $# -gt 0 ]; do
  case "$1" in
    --name) NAME="${2:?--name needs a value}"; shift 2 ;;
    --port) PORT="${2:?--port needs a value}"; shift 2 ;;
    --domain) set_reach domain "${2:?--domain needs a host name}"; shift 2 ;;
    --public-url) set_reach public-url "${2:?--public-url needs an address}"; shift 2 ;;
    --tailscale) set_reach tailscale; shift ;;
    --lan) set_reach lan; shift ;;
    --local-only) set_reach ""; shift ;;
    --bundle) BUNDLE="${2:?--bundle needs a file or an https address}"; shift 2 ;;
    --sha256) SHA256="${2:?--sha256 needs a value}"; shift 2 ;;
    --no-sandbox) SANDBOX=0; shift ;;
    --sandbox) SANDBOX=1; shift ;;
    --no-pair) PAIR=0; shift ;;
    --uninstall) UNINSTALL=1; shift ;;
    --purge) PURGE=1; shift ;;
    -h|--help) sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "unknown option: $1 (see --help)" ;;
  esac
done

[[ "$NAME" =~ ^[a-z][a-z0-9-]{1,24}$ ]] || die "--name must be lowercase letters, digits and dashes"
[ "$(id -u)" -eq 0 ] || die "run it as root (sudo bash install.sh …)"
[ "$(uname -s)" = Linux ] || die "this installer is for Linux servers"
command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ] || die "this server does not run systemd"
command -v ss >/dev/null 2>&1 || die "the 'ss' command is needed to check ports (package iproute2)"

PREFIX="/opt/$NAME"
DATA="/var/lib/$NAME"
UNIT="$NAME-runtime.service"
UNIT_FILE="/etc/systemd/system/$UNIT"
ENV_DIR="/etc/$NAME"
# Written by this installer and only by it: what proves a user, folders and a unit of this name are a Nebulium home's.
MANIFEST="$ENV_DIR/nebulium-install.conf"
MANIFEST_MARK="# nebulium-install v1"
APPARMOR_FILE="/etc/apparmor.d/nebulium-bwrap-$NAME"

ours() { [ -f "$MANIFEST" ] && [ ! -L "$MANIFEST" ] && [ "$(stat -c %u "$MANIFEST")" = 0 ] && [ "$(sed -n 1p "$MANIFEST")" = "$MANIFEST_MARK" ]; }
manifest_value() { sed -n "s/^$1=//p" "$MANIFEST" 2>/dev/null | head -n 1; }

if [ "$UNINSTALL" -eq 1 ]; then
  ours || die "no Nebulium home named '$NAME' was installed by this installer; nothing was removed"
  say "stopping $UNIT"
  systemctl disable --now "$UNIT" >/dev/null 2>&1 || true
  rm -f "$UNIT_FILE"
  systemctl daemon-reload
  rm -rf "$PREFIX"
  if [ "$PURGE" -eq 1 ]; then
    if [ -f "$APPARMOR_FILE" ]; then apparmor_parser -R "$APPARMOR_FILE" >/dev/null 2>&1 || true; rm -f "$APPARMOR_FILE"; fi
    rm -rf "$DATA" "$ENV_DIR"
    if id "$NAME" >/dev/null 2>&1; then userdel "$NAME" >/dev/null 2>&1 || true; fi
    say "removed $NAME, its data and its user"
  else
    say "removed the program; data is kept in $DATA (add --purge to delete it and the user)"
  fi
  exit 0
fi

# --- a name is ours, or free; never someone else's ---
EXISTING=0
if ours; then
  EXISTING=1
else
  for taken in "$PREFIX" "$DATA" "$ENV_DIR" "$UNIT_FILE"; do
    [ ! -e "$taken" ] || die "$taken already exists and was not made by this installer; choose another --name"
  done
  ! id "$NAME" >/dev/null 2>&1 || die "a user named '$NAME' already exists on this server; choose another --name"
fi

# --- options: what was given now, else what this home was installed with, else the defaults ---
if [ "$EXISTING" -eq 1 ]; then
  [ -n "$PORT" ] || PORT="$(manifest_value PORT)"
  [ -n "$SANDBOX" ] || SANDBOX="$(manifest_value SANDBOX)"
  if [ "$REACH_SET" -eq 0 ]; then REACH="$(manifest_value REACH)"; REACH_ARG="$(manifest_value REACH_ARG)"; fi
fi
[ -n "$PORT" ] || PORT=8799
[ -n "$SANDBOX" ] || SANDBOX=1
[[ "$PORT" =~ ^[0-9]{1,5}$ ]] || die "--port must be a number"
PORT=$((10#$PORT))
[ "$PORT" -ge 1024 ] && [ "$PORT" -le 65534 ] || die "--port must be between 1024 and 65534"
WEBHOOK_PORT=$((PORT + 1))
[ "$SANDBOX" = 0 ] || [ "$SANDBOX" = 1 ] || die "the saved sandbox setting is damaged; pass --sandbox or --no-sandbox"
# These two go into the unit's command line, so they are a bare host name and a bare https origin, nothing else.
HOST_RE='^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?)+$'
case "$REACH" in
  domain) [[ "$REACH_ARG" =~ $HOST_RE ]] && [ "${#REACH_ARG}" -le 253 ] || die "--domain takes a host name such as home.example.com" ;;
  public-url)
    [[ "$REACH_ARG" =~ ^https://([^/:]+)(:[0-9]{1,5})?$ ]] && [[ "${BASH_REMATCH[1]}" =~ $HOST_RE ]] && [ "${#REACH_ARG}" -le 300 ] \
      || die "--public-url takes an https address with no path, such as https://home.example.com" ;;
  tailscale|lan|"") REACH_ARG="" ;;
  *) die "the saved way of reaching this home is damaged; pass --domain, --tailscale, --lan, --public-url or --local-only" ;;
esac

case "$(uname -m)" in
  x86_64|amd64) ARCH=x64 ;;
  aarch64|arm64) ARCH=arm64 ;;
  *) die "unsupported processor: $(uname -m)" ;;
esac

# --- the bundle: beside this script, a file, or an address ---
HERE="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd || true)"
WORK=""
SWAPPED=0
ROLLED_BACK=0
WAS_ACTIVE=0

rollback() {
  [ "$SWAPPED" -eq 1 ] && [ "$ROLLED_BACK" -eq 0 ] || return 0
  ROLLED_BACK=1
  if [ "$EXISTING" -eq 1 ] && [ -d "$PREFIX/app.prev" ] && [ -d "$PREFIX/node.prev" ]; then
    echo "install.sh: putting the previous version back" >&2
    systemctl stop "$UNIT" >/dev/null 2>&1 || true
    for part in app node; do rm -rf "${PREFIX:?}/$part"; mv "$PREFIX/$part.prev" "$PREFIX/$part"; done
    [ ! -f "$PREFIX/VERSION.prev" ] || mv -f "$PREFIX/VERSION.prev" "$PREFIX/VERSION"
    [ ! -f "$PREFIX/unit.prev" ] || cp -f "$PREFIX/unit.prev" "$UNIT_FILE"
    [ ! -f "$PREFIX/manifest.prev" ] || cp -f "$PREFIX/manifest.prev" "$MANIFEST"
    rm -f "$PREFIX/unit.prev" "$PREFIX/manifest.prev"
    systemctl daemon-reload || true
    if [ "$WAS_ACTIVE" -eq 1 ]; then systemctl restart "$UNIT" >/dev/null 2>&1 || echo "install.sh: the previous version did not restart; see: journalctl -u $UNIT" >&2; fi
  elif [ "$EXISTING" -eq 0 ]; then
    echo "install.sh: removing the half-made installation" >&2
    systemctl disable --now "$UNIT" >/dev/null 2>&1 || true
    rm -f "$UNIT_FILE"; systemctl daemon-reload || true
    rm -rf "${PREFIX:?}"
  fi
}
finish() {
  code=$?
  [ "$code" -eq 0 ] || rollback
  [ -z "$WORK" ] || rm -rf "$WORK"
  exit "$code"
}
trap finish EXIT

if [ -z "$BUNDLE" ] && [ -n "$HERE" ] && [ -f "$HERE/app/cli.js" ] && [ -x "$HERE/node/bin/node" ]; then
  SRC="$HERE"
else
  WORK="$(mktemp -d)"
  if [ -z "$BUNDLE" ]; then
    # No bundle named: the current release. Which version it is and what each bundle hashes to comes from our site
    # (the list is three lines: "version X", "linux-x64 HASH", "linux-arm64 HASH"); the bundle itself from our
    # download host, and from GitHub when that cannot be reached. The hash is never taken from where the bundle is.
    command -v curl >/dev/null 2>&1 || die "curl is needed to download the bundle"
    # An address that answers is not yet an address that has the thing (a site can answer every path with a page):
    # a list counts when it reads as one, a bundle when it hashes to what the list says. Otherwise the next source.
    read_list() {
      local list
      list="$(curl -fsL --retry 2 --connect-timeout 15 "$1" 2>/dev/null)" || return 1
      LATEST="$(awk '$1 == "version" { print $2 }' <<<"$list" | head -n 1)"
      SHA256="$(awk -v target="linux-$ARCH" '$1 == target { print $2 }' <<<"$list" | head -n 1)"
      [[ "$LATEST" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] && [[ "$SHA256" =~ ^[0-9a-f]{64}$ ]]
    }
    fetch_bundle() {
      curl -fL --retry 2 --connect-timeout 20 -o "$WORK/bundle.tar.gz" "$1" || return 1
      echo "$SHA256  $WORK/bundle.tar.gz" | sha256sum -c - >/dev/null 2>&1
    }
    read_list "$RELEASE_LIST" || read_list "$RELEASE_LIST_FALLBACK" \
      || die "could not read the current release from $RELEASE_LIST or $RELEASE_LIST_FALLBACK; download a bundle yourself and pass --bundle FILE"
    FILE="nebulium-runtime-$LATEST-linux-$ARCH.tar.gz"
    say "downloading Nebulium $LATEST"
    fetch_bundle "$DOWNLOAD_BASE/$LATEST/$FILE" \
      || { say "the main download address did not have it; trying GitHub"; fetch_bundle "$DOWNLOAD_FALLBACK/v$LATEST/$FILE"; } \
      || die "the bundle could not be downloaded, or is not the one the release list names; download it yourself and pass --bundle FILE"
  elif [[ "$BUNDLE" =~ ^https:// ]]; then
    command -v curl >/dev/null 2>&1 || die "curl is needed to download the bundle"
    say "downloading $BUNDLE"
    curl -fL --retry 3 --connect-timeout 20 -o "$WORK/bundle.tar.gz" "$BUNDLE"
    if [ -z "$SHA256" ]; then
      # A checksum from beside the bundle catches a damaged download, not a replaced bundle; --sha256 does both.
      SHA256="$(curl -fsL --retry 3 --connect-timeout 20 "$BUNDLE.sha256" | awk '{print $1}' || true)"
      [ -n "$SHA256" ] || die "no checksum for the bundle: pass --sha256, or publish <bundle>.sha256 beside it"
    fi
  else
    [[ "$BUNDLE" != http://* ]] || die "the bundle address must be https"
    [ -f "$BUNDLE" ] || die "no such bundle file: $BUNDLE"
    cp "$BUNDLE" "$WORK/bundle.tar.gz"
  fi
  if [ -n "$SHA256" ]; then
    [[ "$SHA256" =~ ^[0-9a-fA-F]{64}$ ]] || die "--sha256 takes 64 hex characters"
    echo "$SHA256  $WORK/bundle.tar.gz" | sha256sum -c - >/dev/null 2>&1 || die "the bundle's checksum does not match"
  fi
  mkdir "$WORK/unpacked"
  # Nothing in the bundle may land outside its own folder, and nothing in it keeps an owner from the build machine.
  if tar -tzf "$WORK/bundle.tar.gz" | grep -Eq '(^|/)\.\.(/|$)|^/'; then die "that file is not a Nebulium bundle"; fi
  tar -xzf "$WORK/bundle.tar.gz" -C "$WORK/unpacked" --strip-components=1 --no-same-owner --no-same-permissions
  SRC="$WORK/unpacked"
  [ -f "$SRC/app/cli.js" ] && [ -x "$SRC/node/bin/node" ] || die "that file is not a Nebulium bundle"
fi
BUNDLE_TARGET="$(sed -n 3p "$SRC/VERSION" 2>/dev/null || true)"
[ "$BUNDLE_TARGET" = "linux-$ARCH" ] || die "this bundle is for ${BUNDLE_TARGET:-another platform}; this server needs linux-$ARCH"
"$SRC/node/bin/node" -e 'process.exit(0)' || die "the bundled Node does not run on this server (too old a system?)"

# --- ports: free, or held by this very home ---
unit_pids() { systemctl show -p ControlGroup --value "$UNIT" 2>/dev/null | { read -r group; [ -n "$group" ] && cat "/sys/fs/cgroup$group/cgroup.procs" 2>/dev/null || true; }; }
port_free_or_ours() {
  local listeners pid mine
  listeners="$(ss -Hltnp "sport = :$1" 2>/dev/null || true)"
  [ -n "$listeners" ] || return 0
  mine="$(unit_pids)"
  for pid in $(grep -o 'pid=[0-9]*' <<<"$listeners" | cut -d= -f2 | sort -u); do
    grep -qx "$pid" <<<"$mine" || return 1
  done
  return 0
}
for p in "$PORT" "$WEBHOOK_PORT"; do
  port_free_or_ours "$p" || die "port $p is already in use on this server; choose another with --port"
done
if [ "$REACH" = domain ]; then
  for p in 80 443; do
    port_free_or_ours "$p" || die "--domain needs ports 80 and 443, and $p is in use; use --public-url behind your own HTTPS proxy instead"
  done
fi

# --- the sandbox bots run in ---
if [ "$SANDBOX" -eq 1 ] && ! { command -v bwrap >/dev/null 2>&1 && command -v socat >/dev/null 2>&1; }; then
  say "installing bubblewrap and socat"
  if command -v apt-get >/dev/null 2>&1; then
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq bubblewrap socat >/dev/null
  elif command -v dnf >/dev/null 2>&1; then
    dnf install -y -q bubblewrap socat >/dev/null
  else
    die "install bubblewrap and socat with this system's package manager, then run this again (or pass --no-sandbox)"
  fi
fi

# --- user and folders ---
if [ "$EXISTING" -eq 0 ]; then
  say "creating the system user $NAME"
  useradd --system --user-group --home-dir "$DATA/home" --no-create-home --shell /usr/sbin/nologin "$NAME"
  install -d -o root -g "$NAME" -m 750 "$ENV_DIR"
  printf '%s\n' "$MANIFEST_MARK" > "$MANIFEST"
  chmod 640 "$MANIFEST"; chown root:"$NAME" "$MANIFEST"
fi
install -d -o root -g root -m 755 "$PREFIX"
install -d -o "$NAME" -g "$NAME" -m 700 "$DATA" "$DATA/data" "$DATA/home"
[ -e "$ENV_DIR/runtime.env" ] || install -o root -g "$NAME" -m 640 /dev/null "$ENV_DIR/runtime.env"

# Some systems (Ubuntu 24.04 and later) stop an unprivileged program from making the namespaces bubblewrap needs
# unless an AppArmor profile allows it. Only when bubblewrap really fails for this user, and no profile for it exists
# under any name, a profile of our own name is added; another package's policy is never replaced.
if [ "$SANDBOX" -eq 1 ] && ! runuser -u "$NAME" -- bwrap --unshare-user --unshare-pid --ro-bind / / true >/dev/null 2>&1; then
  if [ "$(sysctl -n kernel.apparmor_restrict_unprivileged_userns 2>/dev/null || echo 0)" = 1 ] && command -v apparmor_parser >/dev/null 2>&1 \
     && ! grep -rqsE '^[[:space:]]*profile[[:space:]]+[^ ]*[[:space:]]*/usr/bin/bwrap|^/usr/bin/bwrap' /etc/apparmor.d 2>/dev/null \
     && ! grep -qs 'bwrap' /sys/kernel/security/apparmor/profiles 2>/dev/null; then
    say "allowing bubblewrap to make its sandbox (AppArmor profile $APPARMOR_FILE)"
    cat > "$APPARMOR_FILE" <<PROFILE
abi <abi/4.0>,
include <tunables/global>

profile nebulium-bwrap-$NAME /usr/bin/bwrap flags=(unconfined) {
  userns,
}
PROFILE
    apparmor_parser -r "$APPARMOR_FILE" || { rm -f "$APPARMOR_FILE"; echo "install.sh: could not load the AppArmor profile" >&2; }
  fi
  runuser -u "$NAME" -- bwrap --unshare-user --unshare-pid --ro-bind / / true >/dev/null 2>&1 \
    || die "bubblewrap cannot make a sandbox for the user $NAME on this server (its security policy forbids it). Allow it, or install with --no-sandbox, where bots run as the home's own user."
fi

# --- stage the new program beside the old one before anything stops ---
rm -rf "$PREFIX/app.new" "$PREFIX/node.new"
cp -R "$SRC/app" "$PREFIX/app.new"
cp -R "$SRC/node" "$PREFIX/node.new"
chown -R root:root "$PREFIX/app.new" "$PREFIX/node.new"
chmod -R go-w "$PREFIX/app.new" "$PREFIX/node.new"

SERVE_ARGS="serve --port $PORT --data-dir $DATA/data --no-pair"
CAPS=""
case "$REACH" in
  domain) SERVE_ARGS="$SERVE_ARGS --domain $REACH_ARG"; CAPS="AmbientCapabilities=CAP_NET_BIND_SERVICE" ;;
  public-url) SERVE_ARGS="$SERVE_ARGS --public-url $REACH_ARG" ;;
  tailscale) SERVE_ARGS="$SERVE_ARGS --tailscale" ;;
  lan) SERVE_ARGS="$SERVE_ARGS --lan" ;;
esac

# --- swap: from here on a failure puts back what was there ---
if systemctl is-active --quiet "$UNIT"; then WAS_ACTIVE=1; fi
if [ "$EXISTING" -eq 1 ]; then
  rm -rf "$PREFIX/app.prev" "$PREFIX/node.prev" "$PREFIX/VERSION.prev" "$PREFIX/unit.prev" "$PREFIX/manifest.prev"
  [ ! -f "$UNIT_FILE" ] || cp "$UNIT_FILE" "$PREFIX/unit.prev"
  cp "$MANIFEST" "$PREFIX/manifest.prev"
  [ ! -f "$PREFIX/VERSION" ] || cp "$PREFIX/VERSION" "$PREFIX/VERSION.prev"
fi
SWAPPED=1
if [ "$WAS_ACTIVE" -eq 1 ]; then say "stopping the running home to upgrade it"; systemctl stop "$UNIT"; fi
for part in app node; do
  [ ! -e "$PREFIX/$part" ] || mv "$PREFIX/$part" "$PREFIX/$part.prev"
  mv "$PREFIX/$part.new" "$PREFIX/$part"
done
cp "$SRC/VERSION" "$PREFIX/VERSION"
cp "$SRC/install.sh" "$PREFIX/install.sh"
chmod 755 "$PREFIX/install.sh"

cat > "$MANIFEST" <<MANIFESTFILE
$MANIFEST_MARK
PORT=$PORT
REACH=$REACH
REACH_ARG=$REACH_ARG
SANDBOX=$SANDBOX
MANIFESTFILE
chmod 640 "$MANIFEST"; chown root:"$NAME" "$MANIFEST"

say "writing $UNIT_FILE"
cat > "$UNIT_FILE" <<UNITFILE
[Unit]
Description=Nebulium home ($NAME, port $PORT)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=$NAME
Group=$NAME
WorkingDirectory=$PREFIX/app
Environment=HOME=$DATA/home
Environment=PATH=$PREFIX/node/bin:/usr/local/bin:/usr/bin:/bin
Environment=OMB_BOT_BOX=$SANDBOX
Environment="OMB_CLI_PREFIX=sudo $PREFIX/cli"
Environment=OMB_DISABLE_MODEL_CATALOG_FETCH=1
Environment=OMB_COMPOSIO_BROKER=off
Environment=OMB_WEBHOOK_PORT=$WEBHOOK_PORT
EnvironmentFile=-$ENV_DIR/runtime.env
ExecStart=$PREFIX/node/bin/node $PREFIX/app/cli.js $SERVE_ARGS
Restart=on-failure
RestartSec=5
UMask=0077
$CAPS

[Install]
WantedBy=multi-user.target
UNITFILE
chmod 644 "$UNIT_FILE"
systemctl daemon-reload
systemctl enable --quiet "$UNIT"
systemctl restart "$UNIT"

# Ready means: this unit is running, and the program answering on the port is one of this unit's own processes.
say "waiting for the home to answer"
READY=0
for _ in $(seq 1 60); do
  systemctl is-active --quiet "$UNIT" || break
  if port_free_or_ours "$PORT" && [ -n "$(ss -Hltn "sport = :$PORT" 2>/dev/null)" ] \
     && "$PREFIX/node/bin/node" -e "fetch('http://127.0.0.1:$PORT/api/health').then(async r=>process.exit(r.ok&&(await r.json()).app==='openmausbot'?0:1),()=>process.exit(1))" 2>/dev/null; then
    READY=1; break
  fi
  sleep 1
done
if [ "$READY" -ne 1 ]; then
  echo "install.sh: the home did not start. Its last lines:" >&2
  journalctl -u "$UNIT" -n 30 --no-pager >&2 || true
  exit 1
fi

if [ "$SANDBOX" -eq 1 ]; then
  # The server says in its log whether the sandbox came up.
  BOX=0
  for _ in $(seq 1 10); do
    if journalctl -u "$UNIT" --since "-3min" --no-pager 2>/dev/null | grep -q "bot box: on"; then BOX=1; break; fi
    sleep 1
  done
  if [ "$BOX" -eq 1 ]; then say "sandbox: on"; else echo "install.sh: WARNING: the sandbox did not come up; bots would run as the home's own user. See: journalctl -u $UNIT" >&2; fi
fi

# The home's own command line, as the home's own user; what the home prints as "run this" names it.
cat > "$PREFIX/cli" <<CLICMD
#!/bin/sh
case "\${1:-}" in
  pair) shift; exec runuser -u $NAME -- env HOME=$DATA/home OMB_CLI_PREFIX="sudo $PREFIX/cli" $PREFIX/node/bin/node $PREFIX/app/cli.js pair --port $PORT --data-dir $DATA/data "\$@" ;;
  *) echo "usage: sudo $PREFIX/cli pair [--phone] [--label NAME] [--ttl 24h]" >&2; exit 2 ;;
esac
CLICMD
cat > "$PREFIX/pair" <<PAIRCMD
#!/bin/sh
# Prints a new pairing code for the Nebulium app.
exec $PREFIX/cli pair "\$@"
PAIRCMD
chmod 755 "$PREFIX/cli" "$PREFIX/pair"
# The new version runs: the installation stands, and the copy kept for a failed start is no longer needed.
SWAPPED=0
rm -rf "$PREFIX/app.prev" "$PREFIX/node.prev" "$PREFIX/VERSION.prev" "$PREFIX/unit.prev" "$PREFIX/manifest.prev"

say "Nebulium $(sed -n 1p "$PREFIX/VERSION") is running as $UNIT (data: $DATA/data)"
case "$REACH" in
  "") echo "    It answers only on this machine (127.0.0.1:$PORT). Run this again with --domain, --tailscale, --lan or --public-url so a phone can reach it." ;;
  domain) echo "    Point DNS for $REACH_ARG at this server; the certificate is fetched by itself once it does." ;;
esac
if [ "$PAIR" -eq 1 ] && [ -n "$REACH" ]; then
  say "pairing code for the Nebulium app (make another later with: sudo $PREFIX/pair)"
  "$PREFIX/pair" || echo "install.sh: could not make a pairing code now; try: sudo $PREFIX/pair" >&2
fi
