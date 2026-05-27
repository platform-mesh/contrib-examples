#!/usr/bin/env bash
#
# hack/tools-kcp.sh — pin the kcp server binary (+ matching kubectl plugins) into bin/.
# Owner: kcp-expert.
#
# Idempotent: re-running is a no-op once the right kcp version is present. Reads the env
# contract exported by Taskfile.yml (KCP_BIN, KCP_VERSION, TASKFILE_DIR); falls back to sane
# defaults so the script also works when invoked directly.
#
# We vendor the version-matched `kubectl-kcp` and `kubectl-ws` plugins alongside kcp so the
# `kubectl ws` / `kubectl create workspace` verbs used by the other kcp scripts are guaranteed
# to match the running server (avoids ws-resolution skew against a stray globally-installed
# plugin). Scripts that need them prepend "$TASKFILE_DIR/bin" to PATH.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TASKFILE_DIR="${TASKFILE_DIR:-$(cd "$SCRIPT_DIR/.." && pwd)}"
KCP_VERSION="${KCP_VERSION:-v0.31.2}"
KCP_BIN="${KCP_BIN:-$TASKFILE_DIR/bin/kcp}"
BIN_DIR="$(dirname "$KCP_BIN")"

# Release tag is vX.Y.Z, but asset filenames drop the leading 'v' (e.g. kcp_0.31.2_darwin_arm64.tar.gz).
VER_NOV="${KCP_VERSION#v}"
OS="$(uname -s | tr '[:upper:]' '[:lower:]')"
ARCH="$(uname -m)"
case "$ARCH" in
  arm64 | aarch64) ARCH=arm64 ;;
  x86_64 | amd64) ARCH=amd64 ;;
  *)
    echo "tools-kcp: unsupported arch '$ARCH'" >&2
    exit 1
    ;;
esac

BASE_URL="https://github.com/kcp-dev/kcp/releases/download/${KCP_VERSION}"

mkdir -p "$BIN_DIR"

# install_tool <asset-prefix> <binary-name-inside-tar> <dest-path>
# Each release tarball lays binaries under bin/<name>; we extract just that and install it.
install_tool() {
  local prefix="$1" binname="$2" dest="$3"
  local asset="${prefix}_${VER_NOV}_${OS}_${ARCH}.tar.gz"
  local url="${BASE_URL}/${asset}"
  local tmp
  tmp="$(mktemp -d)"
  # shellcheck disable=SC2064  # expand $tmp now, at trap-set time
  trap "rm -rf '$tmp'" RETURN
  echo "  downloading ${asset}"
  curl -fsSL -o "$tmp/${asset}" "$url"
  tar -xzf "$tmp/${asset}" -C "$tmp" "bin/${binname}"
  install -m 0755 "$tmp/bin/${binname}" "$dest"
}

# --- kcp server binary (version-checked) ---
# `kcp --version` prints e.g. "kcp version v1.35.1+kcp-v0.31.2" (k8s base + kcp tag); we match the kcp tag.
if [ -x "$KCP_BIN" ] && "$KCP_BIN" --version 2>/dev/null | grep -qF "$KCP_VERSION"; then
  echo "kcp $KCP_VERSION already pinned at $KCP_BIN"
else
  echo "Pinning kcp $KCP_VERSION -> $KCP_BIN"
  install_tool "kcp" "kcp" "$KCP_BIN"
fi

# --- matching kubectl plugins (presence-checked; bin/ is ephemeral, so version skew is a non-issue) ---
for plug in kcp ws; do
  dest="$BIN_DIR/kubectl-${plug}"
  if [ -x "$dest" ]; then
    echo "kubectl-${plug} plugin already present at $dest"
  else
    echo "Pinning kubectl-${plug} plugin -> $dest"
    install_tool "kubectl-${plug}-plugin" "kubectl-${plug}" "$dest"
  fi
done

# --- verify ---
got="$("$KCP_BIN" --version 2>/dev/null || true)"
if ! grep -qF "$KCP_VERSION" <<<"$got"; then
  echo "tools-kcp: ERROR — $KCP_BIN did not report $KCP_VERSION" >&2
  echo "  got: ${got:-<empty>}" >&2
  exit 1
fi
echo "OK: $got"
printf 'OK: bin/ ->'; (cd "$BIN_DIR" && printf ' %s' *); echo
