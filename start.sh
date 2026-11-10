#!/usr/bin/env bash
set -euo pipefail

# Launch Open WebUI (Apple Container) against the native, Metal-accelerated
# Ollama, passing OLLAMA_BASE_URL as a REAL environment variable.
#
# WHY THIS (not container-compose):
#   Apple's container-compose (verified through 1.2.0) does NOT interpolate
#   ${VAR} in compose files, and its -e / --env-file flags do NOT pass the value
#   into the container. The raw `container` CLI DOES support `-e KEY` (inherits
#   the host's env value) and `-e KEY=value`. So we launch with the raw CLI and
#   inject the host-gateway IP via `-e OLLAMA_BASE_URL` — no sed, no placeholder,
#   the repo stays clean.
#
# The Apple Container VM gateway (containers -> host) is the IP the WebUI uses to
# reach Ollama. It is internal to the VM and stable across Wi-Fi/network
# switches, but can change if the VM is recreated. So we detect it at runtime:
#     container run alpine:latest ip route   ->  "default via <GW>"
# Fallback: the Mac's LAN IP. Reachable only because Ollama binds 0.0.0.0:11434
# (baked into ~/Library/LaunchAgents/sh.brew.ollama.plist; survives reboots).
#
# Usage:
#   ./start.sh          # start (default)
#   ./start.sh up       # start
#   ./start.sh down     # stop + remove container
#   ./start.sh restart  # down + up
#   ./start.sh logs     # tail logs
#   ./start.sh status   # health + container state

cd "$(dirname "$0")"

IMAGE="ghcr.io/open-webui/open-webui:main"
NAME="open-webui"
HOST_PORT=3000
CT_PORT=8080
DATA_VOL="${HOME}/.containers/Volumes/open-web-ui/open-webui-data:/app/backend/data"

detect_gw() {
  local gw
  gw="$(container run --rm alpine:latest ip route 2>/dev/null | awk '/default/{print $3}')"
  if [ -z "$gw" ]; then
    gw="$(ipconfig getifaddr en0 2>/dev/null || ipconfig getifaddr en1 2>/dev/null)"
  fi
  if [ -z "$gw" ]; then
    echo "ERROR: could not detect a host IP for Ollama (need Apple Container running + alpine image)." >&2
    exit 1
  fi
  echo "$gw"
}

up() {
  local gw="$1"
  # Export so `container run -e OLLAMA_BASE_URL` inherits it (no value on the flag).
  export OLLAMA_BASE_URL="http://${gw}:11434"
  echo "Resolved Ollama host IP: $gw  ->  OLLAMA_BASE_URL=$OLLAMA_BASE_URL"
  container rm -f "$NAME" 2>/dev/null || true
  container run -d --name "$NAME" -p "${HOST_PORT}:${CT_PORT}" \
    -v "$DATA_VOL" \
    -e OLLAMA_BASE_URL \
    "$IMAGE"
  echo "Started $NAME. Waiting for first-run migration..."
  local i
  for i in $(seq 1 30); do
    if curl -s -o /dev/null --max-time 3 "http://localhost:${HOST_PORT}/health"; then
      echo "WebUI healthy after ~${i}s -> http://localhost:${HOST_PORT}"
      return 0
    fi
    sleep 1
  done
  echo "WARN: health not ready yet; check: container logs $NAME"
}

case "${1:-up}" in
  up)      up "$(detect_gw)" ;;
  down)    container rm -f "$NAME" 2>/dev/null && echo "Stopped $NAME" || echo "$NAME not running" ;;
  restart) container rm -f "$NAME" 2>/dev/null || true; up "$(detect_gw)" ;;
  logs)    container logs "$NAME" ;;
  status)
    curl -s -o /dev/null -w "localhost:${HOST_PORT} -> HTTP %{http_code}\n" --max-time 5 "http://localhost:${HOST_PORT}/health" || echo "not reachable"
    container list 2>&1 | grep -E "$NAME|ID" || true
    ;;
  *) echo "Usage: $0 [up|down|restart|logs|status]" >&2; exit 1 ;;
esac
