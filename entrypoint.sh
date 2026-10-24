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

# 2. the TOTP secret.
#
# Supplied as GPU_TOTP_SECRET (base32, as every authenticator app expects), the
# same way PUBLIC_KEY arrives. When it is absent we generate one and print the
# enrolment URI below, because the alternative — starting a machine that asks
# for a code nobody can produce — is worse than printing a secret to a log the
# operator already controls.
#
# GPU_TOTP_SECRET takes precedence so a fleet can share one enrolment, and so
# restarting a container does not invalidate the operator's phone.
mkdir -p /etc/gpu-gateway
SECRET="${GPU_TOTP_SECRET:-}"
GENERATED=no
if [ -z "$SECRET" ]; then
  if [ "${GPU_TOTP_ENROLL:-true}" = "true" ]; then
    # 20 bytes = 160 bits, which is what RFC 4226 recommends for HMAC-SHA1 and
    # what Google Authenticator's own provisioning uses. Padding is stripped:
    # apps reject '=' in a secret.
    SECRET=$(head -c 20 /dev/urandom | base32 2>/dev/null | tr -d '=\n')
    GENERATED=yes
  fi
fi

if [ -n "$SECRET" ]; then
  printf 'GPU_TOTP_SECRET=%s\nGPU_TOTP_FAILMODE=%s\n' \
    "$SECRET" "${GPU_TOTP_FAILMODE:-open}" > /etc/gpu-gateway/totp.env
  chmod 600 /etc/gpu-gateway/totp.env
  cat > /etc/ssh/sshd_config.d/60-gpu-gate.conf <<'CONF'
ForceCommand /usr/local/sbin/gpu-gate
CONF
  chmod 0644 /etc/ssh/sshd_config.d/60-gpu-gate.conf

  if [ "$GENERATED" = "yes" ]; then
    LABEL="Blackbox GPU:$(hostname 2>/dev/null || echo gpu)"
    URI="otpauth://totp/$(printf '%s' "$LABEL" | sed 's/ /%20/g')?secret=$SECRET&issuer=Blackbox&algorithm=SHA1&digits=6&period=30"
    {
      echo
      echo "=============================================================="
      echo " ENROL YOUR AUTHENTICATOR APP"
      echo
      echo " No GPU_TOTP_SECRET was supplied, so one was generated for"
      echo " this machine. Scan the code below, or enter the key by hand."
      echo " It is shown ONCE, in this log, and nowhere else."
      echo
      echo " key: $SECRET"
      echo
      command -v qrencode >/dev/null 2>&1 && qrencode -t ANSIUTF8 -o - "$URI"
      echo " $URI"
      echo
      echo " Pass GPU_TOTP_SECRET at launch to reuse one enrolment across"
      echo " machines, instead of enrolling each one separately."
      echo "=============================================================="
      echo
    } >&2
  else
    echo "gpu-entrypoint: authenticator challenge enabled from the supplied secret" >&2
  fi
else
  echo "gpu-entrypoint: no GPU_TOTP_SECRET and GPU_TOTP_ENROLL=false — SSH is key-only on this machine" >&2
  rm -f /etc/ssh/sshd_config.d/60-gpu-gate.conf
fi

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
