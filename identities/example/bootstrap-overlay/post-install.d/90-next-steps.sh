# shellcheck shell=bash
# A sourced hook that runs last: a reminder of what provisioning leaves to a person. Replace it
# with your own (copy a key into place, register the box somewhere, start a service).
log "next, as $BOOTSTRAP_TARGET_USER: sign Claude Code in (claude), and put your keys in ~/.env_secrets"
if [ "$BOOTSTRAP_INSTALL_MODE" = dry-run ]; then
    log "install.sh ran as a dry run; provision again with --install to apply it"
fi
