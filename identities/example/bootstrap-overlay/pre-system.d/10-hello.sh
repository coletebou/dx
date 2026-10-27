# shellcheck shell=bash
# A sourced hook (not executable, ends in .sh): it runs in a subshell of the provisioner, with
# set -Eeuo pipefail and the harness's functions (log, warn, die, as_root, as_user, root_write,
# apt_ensure). This one only reports what a hook gets to work with; it changes nothing.
log "overlay $BOOTSTRAP_OVERLAY, hook $BOOTSTRAP_HOOK (phase $BOOTSTRAP_PHASE)"
log "setting up $BOOTSTRAP_TARGET_USER ($BOOTSTRAP_TARGET_HOME) on $BOOTSTRAP_OS_ID $BOOTSTRAP_OS_CODENAME, $BOOTSTRAP_ARCH"
log "mode $BOOTSTRAP_MODE, fast path $BOOTSTRAP_FAST, install.sh $BOOTSTRAP_INSTALL_MODE, dx in $BOOTSTRAP_DX_DIR"
