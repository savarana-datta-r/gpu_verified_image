#!/bin/sh
# Wire the renter's key and the gateway's login gate, then run sshd in the
# foreground as PID 1. Everything here is what cloud-init does on the VM
# providers, compressed into a container start.
set -u

# 1. the renter's keys -> root's authorized_keys (RunPod/Vast convention)
#
# PUBLIC_KEY is the name both providers use and stays the primary. Either
# variable may carry SEVERAL keys, one per line, so a launch can admit a
# person and a CI runner without a second machine. PUBLIC_KEYS is accepted as
# the plural spelling people reach for; both are read and the result is
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

# 2. the gateway's verify config, when the launch asked for it
if [ -n "${GPU_VERIFY_URL:-}" ] && [ -n "${GPU_RUN_TOKEN:-}" ]; then
  printf 'GPU_VERIFY_URL=%s\nGPU_RUN_TOKEN=%s\nGPU_FAILMODE=%s\n' \
    "$GPU_VERIFY_URL" "$GPU_RUN_TOKEN" "${GPU_FAILMODE:-open}" > /etc/gpu-gateway/verify.env
  chmod 600 /etc/gpu-gateway/verify.env
  cat > /etc/ssh/sshd_config.d/60-gpu-gate.conf <<'CONF'
ExposeAuthInfo yes
ForceCommand /usr/local/sbin/gpu-gate
CONF
fi

# 3. the login banner, rendered from what this launch knows.
#    The static /etc/motd baked at build time is the fallback; this overwrites
#    it with the machine's real host, GPU and login. The gate runs the renderer
#    itself, so there is no second copy to keep in step.
mkdir -p /etc/blackbox /etc/gpu-gateway
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
#    the same host identity, and the private half is in the image anyone can
#    pull. ssh-keygen -A writes only the types that are absent, so this is both
#    the normal path and a repair for a partial set.
ssh-keygen -A >/dev/null 2>&1
if [ ! -f /etc/ssh/ssh_host_ed25519_key ]; then
  echo "gpu-entrypoint: could not generate SSH host keys; sshd will refuse to start" >&2
fi

# Validate before committing: a bad drop-in must not stop sshd starting at all.
if ! /usr/sbin/sshd -t 2>/dev/null; then
  echo "gpu-entrypoint: sshd rejected the gate config; removing it" >&2
  rm -f /etc/ssh/sshd_config.d/60-gpu-gate.conf
fi

exec /usr/sbin/sshd -D -e
