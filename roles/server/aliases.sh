# roles/server/aliases.sh — server-role ergonomics, identity-free
#
# Sourced on any server-role machine (Linux headless production or dev
# EC2) regardless of identity. Currently empty — systemctl wrappers
# tend to be service-specific (→ identity file). Placeholder for Commit 2.
#
# Future content possibilities:
# - Generic systemd status helper (journalctl-follow <unit>, etc.)
# - Disk usage / iostat / vmstat shortcuts
# - Standard server firewall/port inspection helpers
