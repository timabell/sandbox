#!/usr/bin/env bash
# Converts a .env file (KEY=VALUE lines) into bwrap --setenv arguments.
# Usage: sandbox.sh ~/work -- $(dotenv2bwrap.sh ~/private/some.env)
set -euo pipefail

[[ -f "${1:-}" ]] || { echo "Usage: dotenv2bwrap.sh <env-file>" >&2; exit 1; }

while IFS='=' read -r key value; do
  [[ -n "$key" && "$key" != \#* ]] && printf -- '--setenv %s %s ' "$key" "$value"
done < "$1"
