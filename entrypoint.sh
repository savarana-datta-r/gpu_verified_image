#!/bin/sh
# Wire the renter's key and the authenticator challenge, then run sshd in the
# foreground as PID 1.
#
# Nothing here contacts a network. The code the gate asks for is checked on
# this machine, so the image runs unchanged on any provider.
set -u

# 1. the renter's keys -> root's authorized_keys (RunPod/Vast convention)
#
# PUBLIC_KEY is the name both providers use and stays the primary. Either
# variable may carry SEVERAL keys, one per line, so a launch can admit a person
# and a CI runner without a second machine. Both are read and the result is
# deduplicated, since the same key arriving twice would otherwise be two
# identical lines.
if [ -n "${PUBLIC_KEY:-}" ] || [ -n "${PUBLIC_KEYS:-}" ]; then
  mkdir -p /root/.ssh && chmod 700 /root/.ssh
  printf '%s\n%s\n' "${PUBLIC_KEY:-}" "${PUBLIC_KEYS:-}" \
    | grep -v '^[[:space:]]*$' \
    | awk '!seen[$0]++' > /root/.ssh/authorized_keys
  chmod 600 /root/.ssh/authorized_keys
  echo "gpu-entrypoint: $(wc -l < /root/.ssh/authorized_keys | tr -d ' ') authorized key(s) installed" >&2
fi

# 2. the authenticator secret, via the shared provisioner.
#
# The same script runs from the sshd wrapper, because Vast and RunPod replace
# this entrypoint and call sshd directly. It is idempotent, so whichever runs
# first wins and the other is a no-op.
/usr/local/sbin/gpu-provision-totp || true

# 3. the login banner, rendered from what this launch knows.
mkdir -p /etc/blackbox
cat > /etc/blackbox/brand.env <<BRAND
BLACKBOX_SERVICE='Blackbox GPU Cloud'
BLACKBOX_HOST='${BLACKBOX_HOST:-$(hostname 2>/dev/null)}'
BLACKBOX_GPU='${BLACKBOX_GPU:-}'
BLACKBOX_LOGIN='${BLACKBOX_LOGIN:-root}'
BLACKBOX_DOCS='https://docs.blackbox.ai'
BLACKBOX_SUPPORT='support@blackbox.ai'
BRAND
chmod 0644 /etc/blackbox/brand.env
if [ -x /etc/blackbox/render-motd.sh ]; then
  /etc/blackbox/render-motd.sh > /etc/motd 2>/dev/null || true
  chmod 0644 /etc/motd 2>/dev/null || true
fi

# 4. host keys, generated per container.
#    The image ships none: a baked set means every machine from that image has
#    the same host identity, and the private half is in an image anyone can
#    pull. ssh-keygen -A writes only the types that are absent, so this is both
#    the normal path and a repair for a partial set. The sshd wrapper does this
#    too, for the providers that replace this entrypoint and call sshd directly.
ssh-keygen -A >/dev/null 2>&1
if [ ! -f /etc/ssh/ssh_host_ed25519_key ]; then
  echo "gpu-entrypoint: could not generate SSH host keys; sshd will refuse to start" >&2
fi

# Validate before committing: a bad drop-in must not stop sshd starting at all.
# A broken challenge degrades to a key-only machine; it never produces a machine
# nobody can log into.
if ! /usr/sbin/sshd -t 2>/dev/null; then
  echo "gpu-entrypoint: sshd rejected the gate config; removing it" >&2
  rm -f /etc/ssh/sshd_config.d/60-gpu-gate.conf
fi

exec /usr/sbin/sshd -D -e
