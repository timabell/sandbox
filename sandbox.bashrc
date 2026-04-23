#!/usr/bin/env bash
# Minimal bashrc for bwrap sandbox - activates mise to get tool paths

# accept mise config from repos we are working on
export MISE_TRUSTED_CONFIG_PATHS="$HOME/work"

eval "$(mise activate bash)"

# dotnet needs DOTNET_ROOT for tool resolution
export DOTNET_ROOT=$(mise where dotnet-core 2>/dev/null)

export PS1="\n╭─[🫙 sandbox ${SANDBOX_OUTER_PWD:-?}] \w\n╰─\$ "
