# sandbox

A [bubblewrap](https://github.com/containers/bubblewrap) sandbox for running Claude Code and npm/dotnet builds in isolation.

Inspired by [Patrick McCanna's detailed writeup on Claude Code constrained by bubblewrap](https://patrickmccanna.net/a-detailed-writeup-of-claude-code-constrained-by-bubblewrap/).

## Usage

```bash
# No args: mounts $PWD at ~/work
./sandbox.sh

# Single path: mounts that path at ~/work
./sandbox.sh ~/my-project

# Multiple paths: mounts each at ~/work/<basename>
./sandbox.sh ~/project-a ~/project-b

# Everything after "--" is passed directly to bwrap (e.g. --setenv, --ro-bind)
./sandbox.sh ~/work -- --setenv API_KEY val

# Mount an extra directory read-only (visible but not writable inside the sandbox)
./sandbox.sh ~/work -- --ro-bind ~/shared-assets /home/user/assets

# Mount an extra directory read-write (e.g. a shared build cache)
./sandbox.sh ~/work -- --bind ~/build-cache /home/user/build-cache

# Inject .env secrets into a build sandbox
./sandbox.sh ~/work -- $(./dotenv2bwrap.sh ~/private/some.env)
```

## Dependencies

- [bubblewrap](https://github.com/containers/bubblewrap) (`bwrap`)
- [mise](https://mise.jdx.dev/) (tool version manager, for node/dotnet/claude toolchains)
- bash
- Linux kernel 6.2+ (for TIOCSTI protection via `CONFIG_LEGACY_TIOCSTI=n`)

## Threat Model

This sandbox addresses two distinct threats:

### 1. AI assistant exfiltrating secrets

Claude is semi-trusted -- it follows instructions but can be misled by prompt injection, hallucinate dangerous commands, or act on malicious content in files it reads. Without a sandbox it has full access to the user's home directory, SSH keys, cloud credentials, other repos, and shell history. Anything it can read, it can send to the cloud as part of normal API conversation. It can also run destructive commands beyond its work area -- `rm -rf /` has been reported in the wild. The sandbox limits what it can discover and what it can damage by confining visibility and writes to the working directory.

### 2. Supply chain attacks during builds

npm/dotnet builds pull packages from public registries. A compromised package can execute arbitrary code via postinstall scripts, native addons, or `child_process` -- including downloading and running further payloads from the internet, dark web, or blockchain. This is indistinguishable from running an untrusted binary. The sandbox constrains the blast radius whether or not the AI triggered the build.

### How the sandbox constrains both

- **Filesystem**: only explicitly bind-mounted paths are visible. The host home directory, SSH keys, cloud credentials, and other repos are not reachable.
- **Environment**: `--clearenv` wipes host variables. Only the minimum needed (`HOME`, `USER`, `TERM`, `PATH`) is set explicitly -- no leaked tokens or secrets from the host shell.
- **Processes**: `--unshare-pid` gives an isolated PID namespace so the sandbox cannot see or signal host processes.
- **Network**: currently unrestricted (builds need registry/API access). This is the largest remaining gap -- a compromised package can exfiltrate data or pull further payloads. Network filtering (e.g. via slirp4netns or firewall rules) is a future improvement.

## Two-sandbox pattern

Some projects need secrets at runtime (OAuth client IDs, API keys) but Claude should never see them -- anything it can read, it can exfiltrate via normal API conversation. Pass secrets to a build sandbox via `--` and bwrap's `--setenv` (e.g. `sandbox.sh ~/work -- --setenv KEY val`).

Running two sandboxes on the same working directory -- one with secrets for builds, one without for Claude -- gives the build process what it needs while keeping secrets out of Claude's environment, filesystem, and `/proc`. The working directory is bind-mounted into both, so Claude's edits are immediately visible to the build sandbox (and vice versa).

## Not yet covered

- **Exfiltration of necessary tokens**: the AI's own API auth tokens (`~/.claude`, `~/.claude.json`) and build secrets needed for private feeds (`~/.nuget` credential provider). These are mounted read-write today. Making them read-only would prevent tampering but they remain readable -- and anything readable can be exfiltrated over the network.
- **Kernel exploits** from within the sandbox (see [seccomp notes](#seccomp) below).
- **Exfiltration over the network** (the largest gap -- both threats can use it).
- **Attacks against the mounted working directory** itself (the code being built is necessarily writable).

## Seccomp

Seccomp (`--seccomp` / `--add-seccomp-fd`) is not currently used. A compromised npm package can pull and execute arbitrary native payloads (via postinstall scripts, native addons, `child_process`), so the threat model does justify syscall filtering as defence-in-depth.

### What the kernel already restricts (on 6.8)

- **TIOCSTI injection**: blocked since 6.2 (`CONFIG_LEGACY_TIOCSTI` defaults to `n`).
  [kernel commit](https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git/commit/?id=83efeeeb3d04b22aaed1df99bc70a48fe9d22c4d)
- **userfaultfd kernel-mode faults**: unprivileged access restricted since 5.5
  (`vm.unprivileged_userfaultfd` defaults to 0, requires `CAP_SYS_PTRACE`).
  [kernel commit](https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git/commit/?id=2d5de004e009add27db76c5cdc9f1f7f7dc087e7)

### What the kernel does NOT restrict

**io_uring**: `sysctl io_uring_disabled` was added in 6.6 but defaults to 0 (allow all). Check with:

```bash
cat /proc/sys/kernel/io_uring_disabled
# 0=allow all, 1=unprivileged denied, 2=disabled
```

io_uring remains a significant attack surface -- Google reported 60% of kernel exploits in their 2022 bug bounty targeted it, and disabled it in ChromeOS, Android apps, and Google servers.
[Google security blog](https://security.googleblog.com/2023/06/learnings-from-kctf-vrps-42-linux.html),
[Phoronix coverage](https://www.phoronix.com/news/Google-Restricting-IO_uring).

Recommended mitigation: set `io_uring_disabled=1` via sysctl. This denies unprivileged processes (which includes everything inside bwrap) while leaving io_uring available to privileged host processes that need it.

```bash
# Temporary
echo 1 | sudo tee /proc/sys/kernel/io_uring_disabled

# Persistent
echo 'kernel.io_uring_disabled = 1' | sudo tee /etc/sysctl.d/50-disable-io-uring.conf && sudo sysctl --system
```

Value 2 disables for all processes including privileged ones.

### Why seccomp is not yet enabled

The namespace/filesystem isolation (`unshare-pid`, `clearenv`, bind mounts) is the primary defence. Seccomp would add a second wall -- particularly for io_uring and against kernel namespace escape bugs -- but requires generating and maintaining a BPF allowlist (via libseccomp) that permits everything node/dotnet legitimately needs, and breaks when toolchains add new syscalls.

Revisit if:
- A namespace escape lands that seccomp would have blocked.
- Tooling improves (e.g. bwrap gains a built-in default profile).
- We want to block io_uring (simplest win -- single syscall to deny).

## License

[GNU Affero General Public License v3.0](LICENSE)
