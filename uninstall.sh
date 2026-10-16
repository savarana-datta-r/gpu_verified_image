#!/bin/bash
# Removes the SSH login gate. Leaves sshd running and reachable.
#
# Order matters. The running daemon keeps its loaded ForceCommand until it is
# reloaded, so the gate script is deleted LAST — only once the reload has been
# confirmed. Deleting it first would leave a daemon pointing ForceCommand at a
# file that no longer exists, which breaks every login on the machine.
set -uo pipefail
[ "$(id -u)" = "0" ] || { echo "uninstall: run as root (sudo)" >&2; exit 1; }
SSHD=$(command -v sshd || echo /usr/sbin/sshd)

# 1. the configuration that invokes the gate
rm -f /etc/ssh/sshd_config.d/60-gpu-gate.conf
if grep -q '^ForceCommand /usr/local/sbin/gpu-gate' /etc/ssh/sshd_config 2>/dev/null; then
  sed -i.gpugate-bak '/^ExposeAuthInfo yes$/d; /^ForceCommand \/usr\/local\/sbin\/gpu-gate$/d' \
    /etc/ssh/sshd_config
fi

# 2. the config must be valid before we ask sshd to take it
if ! ERR=$("$SSHD" -t 2>&1); then
  echo "uninstall: sshd config is invalid after removal, so nothing was reloaded: $ERR" >&2
  echo "uninstall: the gate is still in place and logins still work. Fix sshd_config, then rerun." >&2
  exit 1
fi

# 3. reload, and only count it if something actually accepted the reload
RELOADED=0
if   systemctl reload ssh   2>/dev/null; then RELOADED=1
elif systemctl reload sshd  2>/dev/null; then RELOADED=1
elif service ssh reload     2>/dev/null; then RELOADED=1
elif service sshd reload    2>/dev/null; then RELOADED=1
elif [ -f /var/run/sshd.pid ] && kill -HUP "$(cat /var/run/sshd.pid)" 2>/dev/null; then RELOADED=1
fi

if [ "$RELOADED" != "1" ]; then
  echo "uninstall: could not reload sshd. The gate script has been LEFT IN PLACE on purpose," >&2
  echo "uninstall: because the running daemon still refers to it and removing it now would" >&2
  echo "uninstall: break every login. Reload sshd yourself, then rerun this script." >&2
  exit 1
fi

# 4. now that no daemon refers to it, the gate itself
rm -f /usr/local/sbin/gpu-gate /etc/gpu-gateway/verify.env
rmdir /etc/gpu-gateway 2>/dev/null || true
echo "uninstall: gate removed"
