#!/usr/bin/env bash
# bwrap sandbox for running claude & npm/dotnet builds
# Usage: sandbox.sh [path ...] [-- extra-bwrap-args ...]
#   No args:  mounts $PWD at ~/work
#   One path: mounts that path at ~/work
#   2+ paths: mounts each at ~/work/<basename>
#   --:       everything after "--" is passed directly to bwrap (e.g. --setenv, --ro-bind)
# Inspired by https://patrickmccanna.net/a-detailed-writeup-of-claude-code-constrained-by-bubblewrap/
# Depends on bubblewrap https://github.com/containers/bubblewrap
#
# Threat model
#
# This sandbox addresses two distinct threats:
#
# 1. AI assistant exfiltrating secrets
#    Claude is semi-trusted — it follows instructions but can be misled by
#    prompt injection, hallucinate dangerous commands, or act on malicious
#    content in files it reads. Without a sandbox it has full access to the
#    user's home directory, SSH keys, cloud credentials, other repos, and
#    shell history. Anything it can read, it can send to the cloud as part
#    of normal API conversation. It can also run destructive commands beyond
#    its work area — rm -rf / has been reported in the wild. The sandbox
#    limits what it can discover and what it can damage by confining
#    visibility and writes to the working directory.
#
# 2. Supply chain attacks during builds
#    npm/dotnet builds pull packages from public registries. A compromised
#    package can execute arbitrary code via postinstall scripts, native
#    addons, or child_process — including downloading and running further
#    payloads from the internet, dark web, or blockchain. This is
#    indistinguishable from running an untrusted binary. The sandbox
#    constrains the blast radius whether or not the AI triggered the build.
#
# How the sandbox constrains both:
#   - Filesystem: only explicitly bind-mounted paths are visible. The host
#     home directory, SSH keys, cloud credentials, and other repos are not
#     reachable.
#   - Environment: --clearenv wipes host variables. Only the minimum needed
#     (HOME, USER, TERM, PATH) is set explicitly — no leaked tokens or
#     secrets from the host shell.
#   - Processes: --unshare-pid gives an isolated PID namespace so the sandbox
#     cannot see or signal host processes.
#   - Network: currently unrestricted (builds need registry/API access).
#     This is the largest remaining gap — a compromised package can exfiltrate
#     data or pull further payloads. Network filtering (e.g. via slirp4netns
#     or firewall rules) is a future improvement.
#
# Two-sandbox pattern (extra bwrap args via "--"):
#   Some projects need secrets at runtime (OAuth client IDs, API keys) but
#   Claude should never see them — anything it can read, it can exfiltrate
#   via normal API conversation. Pass secrets to a build sandbox via
#   "--" and bwrap's --setenv (e.g. sandbox.sh ~/work -- --setenv KEY val).
#   Running two sandboxes on the same working directory — one with secrets
#   for builds, one without for Claude — gives the build process what it
#   needs while keeping secrets out of Claude's environment, filesystem,
#   and /proc. The working directory is bind-mounted into both, so Claude's
#   edits are immediately visible to the build sandbox (and vice versa).
#
# Not yet covered:
#   - Exfiltration of tokens that must be present to function: the AI's own
#     API auth tokens (~/.claude, ~/.claude.json) and build secrets needed for
#     private feeds (~/.nuget credential provider). These are mounted read-write
#     today. Making them read-only would prevent tampering but they remain
#     readable — and anything readable can be exfiltrated over the network.
#   - Kernel exploits from within the sandbox (see seccomp notes at end of file)
#   - Exfiltration over the network (the largest gap — both threats can use it)
#   - Attacks against the mounted working directory itself (the code being
#     built is necessarily writable)

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SANDBOX_HOME="/home/user"
MISE_DATA="$HOME/.local/share/mise"

# Split args on "--": paths before, extra bwrap args after
paths=()
extra_args=()
while [[ $# -gt 0 ]]; do
  if [[ "$1" == "--" ]]; then
    shift
    extra_args=("$@")
    break
  fi
  paths+=("$1")
  shift
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
  --ro-bind "$HOME/.config/mise" "$SANDBOX_HOME/.config/mise"
  --ro-bind "$HOME/dm" "$HOME/dm"               # symlink target for dotfiles managed via ~/dm, without this linked config files can't be read

  # claude config + state (future work to deny write)
  --bind "$HOME/.claude" "$SANDBOX_HOME/.claude"
  --bind "$HOME/.claude.json" "$SANDBOX_HOME/.claude.json"

  # nuget: packages, plugins (credential provider), and config
  --bind "$HOME/.nuget" "$SANDBOX_HOME/.nuget"

  # shell profile that activates mise
  --ro-bind "$SCRIPT_DIR/sandbox.bashrc" "$SANDBOX_HOME/.bashrc"

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

# Append any extra bwrap args passed after "--"
args+=("${extra_args[@]}")

args+=(--chdir "$SANDBOX_HOME/work")    # start in the working directory

bwrap "${args[@]}" -- /usr/bin/bash

# Seccomp (--seccomp / --add-seccomp-fd)
#
# Not currently used. A compromised npm package can pull and execute arbitrary
# native payloads (via postinstall scripts, native addons, child_process), so
# the threat model does justify syscall filtering as defence-in-depth.
#
# What the kernel already restricts (on 6.8):
#   - TIOCSTI injection: blocked since 6.2 (CONFIG_LEGACY_TIOCSTI defaults to n)
#     https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git/commit/?id=83efeeeb3d04b22aaed1df99bc70a48fe9d22c4d
#   - userfaultfd kernel-mode faults: unprivileged access restricted since 5.5
#     (vm.unprivileged_userfaultfd defaults to 0, requires CAP_SYS_PTRACE)
#     https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git/commit/?id=2d5de004e009add27db76c5cdc9f1f7f7dc087e7
#
# What the kernel does NOT restrict:
#   - io_uring: sysctl io_uring_disabled was added in 6.6 but defaults to 0
#     (allow all). Check with: cat /proc/sys/kernel/io_uring_disabled
#     (0=allow all, 1=unprivileged denied, 2=disabled).
#     io_uring remains a significant attack surface — Google reported 60% of
#     kernel exploits in their 2022 bug bounty targeted it, and disabled it in
#     ChromeOS, Android apps, and Google servers.
#     https://security.googleblog.com/2023/06/learnings-from-kctf-vrps-42-linux.html
#     https://www.phoronix.com/news/Google-Restricting-IO_uring
#     Recommended mitigation: set io_uring_disabled=1 via sysctl. This denies
#     unprivileged processes (which includes everything inside bwrap) while
#     leaving io_uring available to privileged host processes that need it.
#     Temporary:  echo 1 | sudo tee /proc/sys/kernel/io_uring_disabled
#     Persistent: echo 'kernel.io_uring_disabled = 1' | sudo tee /etc/sysctl.d/50-disable-io-uring.conf && sudo sysctl --system
#     Value 2 disables for all processes including privileged ones.
#
# The namespace/filesystem isolation (unshare-pid, clearenv, bind mounts) is
# the primary defence. Seccomp would add a second wall — particularly for
# io_uring and against kernel namespace escape bugs — but requires generating
# and maintaining a BPF allowlist (via libseccomp) that permits everything
# node/dotnet legitimately needs, and breaks when toolchains add new syscalls.
#
# Revisit if:
#   - a namespace escape lands that seccomp would have blocked
#   - tooling improves (e.g. bwrap gains a built-in default profile)
#   - we want to block io_uring (simplest win — single syscall to deny)
