# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

A bubblewrap (bwrap) sandbox for running Claude Code and npm/dotnet builds in isolation. Prevents AI assistants from exfiltrating secrets and constrains supply chain attack blast radius from compromised packages.

## Repository Structure

- `sandbox.sh` - Main sandbox script. Wraps bwrap with bind mounts, environment isolation, and PID namespacing.
- `dotenv2bwrap.sh` - Converts `.env` files into `--setenv` arguments for passing secrets to a build sandbox without exposing them to Claude.
- `sandbox.bashrc` - Shell profile loaded inside the sandbox; activates mise and sets the prompt.

## Usage

```bash
# Single directory (mounts at ~/work)
./sandbox.sh [path]

# Multiple directories (mounts each at ~/work/<basename>)
./sandbox.sh path1 path2

# Pass extra bwrap args (e.g. secrets for builds)
./sandbox.sh ~/work -- --setenv API_KEY val

# Inject .env secrets into build sandbox
./sandbox.sh ~/work --env-file ~/private/some.env
```

## Development Notes

- Pure bash scripts, no build step or dependency manager.
- External dependencies: bubblewrap (`bwrap`), mise (tool version manager), bash.
- No test suite currently exists.
- The sandbox runs on Linux with kernel 6.2+ (for TIOCSTI protection via `CONFIG_LEGACY_TIOCSTI=n`).

## Security Model

Two-threat model: (1) AI exfiltrating secrets via API conversation, (2) supply chain attacks from compromised packages during builds.

Mitigations: filesystem confinement via bind mounts, `--clearenv` to strip host environment, `--unshare-pid` for PID namespace isolation.

Known gap: network is unrestricted (builds need registry/API access), so exfiltration over the network is possible.

Two-sandbox pattern: run one sandbox with secrets (for builds) and one without (for Claude) on the same working directory.
