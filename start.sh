#!/usr/bin/env bash
set -euo pipefail

# Launch Open WebUI against the native, Metal-accelerated Ollama, auto-detecting
# the host-gateway IP the Apple Container VM uses to reach the Mac.
#
# WHY: Apple Container provides no `host.docker.internal`, no `--add-host`, and
# no ${VAR} interpolation in compose files. The gateway IP that containers use
# to reach the host is NOT static (it can change if the VM is recreated), so we
# detect it at runtime and substitute it into compose.yml before launching.
#
# Usage:  ./start.sh          (optionally: ./start.sh down)

cd "$(dirname "$0")"

CMD="${1:-up}"

# 1. Detect the Apple Container host gateway. Most stable across Wi-Fi / network
#    switches because it is internal to the VM. Fallback to the Mac's LAN IP.
GW="$(container run --rm alpine:latest ip route 2>/dev/null | awk '/default/{print $3}')"
if [ -z "$GW" ]; then
  GW="$(ipconfig getifaddr en0 2>/dev/null || ipconfig getifaddr en1 2>/dev/null)"
fi
if [ -z "$GW" ]; then
  echo "ERROR: could not detect a host IP for Ollama (need Apple Container running + alpine image)." >&2
  exit 1
fi
echo "Resolved Ollama host IP: $GW"

PLACEHOLDER="__OLLAMA_HOST_IP__"

# 2. If stopping, just delegate (no substitution needed).
if [ "$CMD" != "up" ]; then
  container-compose "$CMD"
  exit 0
fi

# 3. Substitute the placeholder in the OLLAMA_BASE_URL value line only, launch,
#    then restore compose.yml so git stays clean. The running container already
#    captured the value at creation time, so restoring afterward is safe.
if ! grep -q "$PLACEHOLDER" compose.yml; then
  echo "NOTE: compose.yml has no $PLACEHOLDER — launching as-is." >&2
  container-compose up -d
  exit 0
fi

cp compose.yml /tmp/compose.yml.bak."$$"
# Anchor the substitution to the OLLAMA_BASE_URL value line only.
sed -i '' "s|^\( *OLLAMA_BASE_URL: *http://\)$PLACEHOLDER|\1$GW|" compose.yml
# up may report a benign "timed out waiting" while the container starts async.
container-compose up -d || true
mv /tmp/compose.yml.bak."$$" compose.yml
echo "compose.yml restored (placeholder intact); running container uses $GW."
