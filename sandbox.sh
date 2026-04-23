#!/usr/bin/env bash
# See README.md for full documentation, threat model, and seccomp notes.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SANDBOX_HOME="/home/user"
MISE_DATA="$HOME/.local/share/mise"

# Split args: paths, --env-file flags, and extra bwrap args (after "--")
paths=()
env_files=()
extra_args=()
while [[ $# -gt 0 ]]; do
  if [[ "$1" == "--" ]]; then
    shift
    extra_args=("$@")
    break
  elif [[ "$1" == "--env-file" ]]; then
    shift
    [[ -f "${1:-}" ]] || { echo "Error: env file not found: ${1:-}" >&2; exit 1; }
    env_files+=("$1")
    shift
  else
    paths+=("$1")
    shift
  fi
done
# Default to $PWD if no paths given
if [[ ${#paths[@]} -eq 0 ]]; then paths=("$PWD"); fi

# Resolve all paths to absolute
resolved=()
for p in "${paths[@]}"; do
  resolved+=("$(readlink -f "$p")")
done

args=(
  --ro-bind /usr /usr                   # core binaries (bash, coreutils, etc.)
  --ro-bind /lib /lib                   # shared libraries (glibc etc.)
  --ro-bind /lib64 /lib64               # dynamic linker
  --ro-bind /bin /bin                   # essential binaries
  --proc /proc                          # process info, needed by node/dotnet
  --dev /dev                            # /dev/null, /dev/urandom, etc.
  --tmpfs /tmp                          # isolated ephemeral tmp (not host's)

  # DNS resolution (claude API, npm registry, nuget)
  --ro-bind /etc/resolv.conf /etc/resolv.conf
  --ro-bind /etc/nsswitch.conf /etc/nsswitch.conf
  --ro-bind /etc/hosts /etc/hosts
  --ro-bind /etc/ssl /etc/ssl           # TLS certificates (HTTPS for nuget, npm, claude API)
  --ro-bind /etc/passwd /etc/passwd     # user name resolution (needed for `claude --resume` to work)

  # mise-managed toolchains (node, dotnet, claude)
  --ro-bind "$MISE_DATA" "$SANDBOX_HOME/.local/share/mise"

  # claude config + state (future work to deny write)
  --bind "$HOME/.claude" "$SANDBOX_HOME/.claude"
  --bind "$HOME/.claude.json" "$SANDBOX_HOME/.claude.json"

  # nuget: packages, plugins (credential provider), and config
  --bind "$HOME/.nuget" "$SANDBOX_HOME/.nuget"

  # shell profile that activates mise
  --ro-bind "$SCRIPT_DIR/sandbox.bashrc" "$SANDBOX_HOME/.bashrc"

  # bind dotfile to home folder
  --ro-bind "$SCRIPT_DIR/dotfiles/.config/" "$SANDBOX_HOME/.config"

  --unshare-pid                         # own PID namespace so /proc doesn't leak host processes
  # --new-session not needed: TIOCSTI injection blocked by kernel ≥6.2 (LEGACY_TIOCSTI=n)

  --clearenv                            # wipe host env; only explicitly set vars are visible
  --setenv HOME "$SANDBOX_HOME"         # remap HOME so tools write to sandbox
  --setenv USER "user"
  --setenv TERM "${TERM:-xterm-256color}"
  --setenv PATH "/usr/local/bin:/usr/bin:/bin"  # minimal PATH; mise activate extends it
)

# Mount working directories and set SANDBOX_OUTER_PWD
if [[ ${#resolved[@]} -eq 1 ]]; then
  # Single path: mount directly at ~/work (original behaviour)
  args+=(
    --bind "${resolved[0]}" "$SANDBOX_HOME/work"
    --setenv SANDBOX_OUTER_PWD "${resolved[0]}"
  )
else
  # Multiple paths: mount each at ~/work/<basename>
  # Create a tmpfs at ~/work so subdirectories can be bind-mounted into it
  args+=(--tmpfs "$SANDBOX_HOME/work")
  outer_list=""
  for p in "${resolved[@]}"; do
    name="$(basename "$p")"
    args+=(--bind "$p" "$SANDBOX_HOME/work/$name")
    outer_list+="${outer_list:+:}$p"
  done
  args+=(--setenv SANDBOX_OUTER_PWD "$outer_list")
fi

# Load .env files into --setenv args (handles spaces and quotes correctly)
for env_file in "${env_files[@]}"; do
  while IFS='=' read -r key value; do
    [[ -n "$key" && "$key" != \#* ]] || continue
    value="${value#\"}" ; value="${value%\"}"
    value="${value#\'}" ; value="${value%\'}"
    args+=(--setenv "$key" "$value")
  done < "$env_file"
done

# Append any extra bwrap args passed after "--"
args+=("${extra_args[@]}")

args+=(--chdir "$SANDBOX_HOME/work")    # start in the working directory

bwrap "${args[@]}" -- /usr/bin/bash
