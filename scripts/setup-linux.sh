#!/usr/bin/env sh
# One-step Linux setup: system packages, Zig, source dependencies, then a build.
# Set SKIP_PACKAGES=1 to leave system packages alone. Extra arguments go to `zig build`.
set -eu
cd "$(dirname "$0")/.."
zig_version=0.17.0

if [ "${SKIP_PACKAGES:-0}" != 1 ]; then
  sudo=
  [ "$(id -u)" = 0 ] || sudo=sudo
  if command -v apt-get >/dev/null 2>&1; then
    $sudo apt-get update
    $sudo apt-get install -y build-essential cmake git curl xz-utils pkg-config libssl-dev libwayland-dev wayland-protocols libxkbcommon-dev libdbus-1-dev libvulkan1
  elif command -v dnf >/dev/null 2>&1; then
    $sudo dnf install -y gcc gcc-c++ make cmake git curl xz pkgconf-pkg-config openssl-devel wayland-devel wayland-protocols-devel libxkbcommon-devel dbus-devel vulkan-loader
  elif command -v pacman >/dev/null 2>&1; then
    $sudo pacman -S --needed --noconfirm base-devel cmake git curl xz openssl wayland wayland-protocols libxkbcommon dbus vulkan-icd-loader
  elif command -v zypper >/dev/null 2>&1; then
    $sudo zypper --non-interactive install gcc gcc-c++ make cmake git curl xz pkg-config libopenssl-devel wayland-devel wayland-protocols-devel libxkbcommon-devel dbus-1-devel libvulkan1
  else
    echo "Unknown package manager. Install a C/C++ compiler, cmake, git, curl, xz, pkg-config and the development packages for OpenSSL, Wayland, wayland-protocols, xkbcommon and D-Bus, plus the Vulkan loader, then rerun with SKIP_PACKAGES=1." >&2
    exit 1
  fi
fi

if command -v zig >/dev/null 2>&1 && [ "$(zig version)" = "$zig_version" ]; then
  zig=zig
else
  case "$(uname -m)" in
    x86_64) arch=x86_64 sum=1cbe9df9f27e6b78d14ccbca43b6703a404ef79ef1c463de901d7f088d4e2026 ;;
    aarch64) arch=aarch64 sum=9e8d11661d4ae3bd57702a3832781e23ad151dde5798e16a5ccd503f65234ff8 ;;
    *) echo "No pinned Zig $zig_version download for $(uname -m); install it yourself and put it on PATH." >&2; exit 1 ;;
  esac
  name="zig-$arch-linux-$zig_version"
  zig="$PWD/.tools/$name/zig"
  if [ ! -x "$zig" ]; then
    mkdir -p .tools
    curl -fL -o ".tools/$name.tar.xz" "https://ziglang.org/download/$zig_version/$name.tar.xz"
    echo "$sum  .tools/$name.tar.xz" | sha256sum -c -
    tar -xJf ".tools/$name.tar.xz" -C .tools
    rm ".tools/$name.tar.xz"
  fi
fi

sh scripts/bootstrap.sh
"$zig" build "$@"
echo "Built zig-out/bin/weaver. Run it with: $zig build run"
