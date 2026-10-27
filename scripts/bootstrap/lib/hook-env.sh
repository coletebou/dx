# shellcheck shell=bash
# hook-env.sh: for an executable bash overlay hook, the helpers a sourced hook already has:
#
#   . "$BOOTSTRAP_LIB/hook-env.sh"
#   log "hello from $BOOTSTRAP_HOOK"; apt_ensure jq; root_write /etc/example.conf "key = value"
#
# Gives log, warn, die, as_root, as_user, as_user_fn, root_write, apt_ensure, apt_get and
# fetch_verified, with TARGET_USER and TARGET_HOME set from the hook's environment.
_hook_env_dir="${BASH_SOURCE[0]%/*}"
# shellcheck source=scripts/bootstrap/lib/harness.sh
. "$_hook_env_dir/harness.sh"
# shellcheck source=scripts/bootstrap/lib/system.sh
. "$_hook_env_dir/system.sh"
unset _hook_env_dir
TARGET_USER="${BOOTSTRAP_TARGET_USER:-$(id -un)}"
TARGET_HOME="${BOOTSTRAP_TARGET_HOME:-$HOME}"
BOOTSTRAP_TAG="${BOOTSTRAP_HOOK:-hook}"
