#!/bin/sh
# Wire the renter's key and the gateway's login gate, then run sshd in the
# foreground as PID 1. Everything here is what cloud-init does on the VM
# providers, compressed into a container start.
set -u

# 1. the renter's key -> root's authorized_keys (RunPod/Vast convention)
if [ -n "${PUBLIC_KEY:-}" ]; then
  mkdir -p /root/.ssh && chmod 700 /root/.ssh
  printf '%s\n' "$PUBLIC_KEY" > /root/.ssh/authorized_keys
  chmod 600 /root/.ssh/authorized_keys
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

# 3. host keys, if the image was built without them
[ -f /etc/ssh/ssh_host_ed25519_key ] || ssh-keygen -A >/dev/null 2>&1

# Validate before committing: a bad drop-in must not stop sshd starting at all.
if ! /usr/sbin/sshd -t 2>/dev/null; then
  echo "gpu-entrypoint: sshd rejected the gate config; removing it" >&2
  rm -f /etc/ssh/sshd_config.d/60-gpu-gate.conf
fi

exec /usr/sbin/sshd -D -e
