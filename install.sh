#!/bin/bash
# Installs the SSH login gate onto a machine that already exists.
#
# Use this on a GPU VM — Lambda, a bare-metal box, any Ubuntu or Debian host
# with sshd — where you cannot or do not want to replace the image. On hosts
# where the machine is a container, use the image instead; it carries the same
# gate and this script has no init system to work with.
#
#   curl -fsSL https://raw.githubusercontent.com/savarana-datta-r/gpu_verified_image/main/install.sh \
#     | sudo GPU_VERIFY_URL=https://… GPU_RUN_TOKEN=… bash
#
# Idempotent: running it twice leaves the machine in the same state.
set -uo pipefail

GATE_URL="${GATE_URL:-https://raw.githubusercontent.com/savarana-datta-r/gpu_verified_image/main/gpu-gate}"
VERIFY_URL="${GPU_VERIFY_URL:-}"
RUN_TOKEN="${GPU_RUN_TOKEN:-}"
FAILMODE="${GPU_FAILMODE:-open}"

die() { echo "install: $*" >&2; exit 1; }

[ "$(id -u)" = "0" ] || die "run as root (sudo)"
[ -n "$VERIFY_URL" ] || die "GPU_VERIFY_URL is not set"
[ -n "$RUN_TOKEN" ]  || die "GPU_RUN_TOKEN is not set"
command -v sshd >/dev/null 2>&1 || command -v /usr/sbin/sshd >/dev/null 2>&1 \
  || die "no sshd on this machine; nothing to gate"
case "$FAILMODE" in open|closed) ;; *) die "GPU_FAILMODE must be 'open' or 'closed'";; esac

SSHD=$(command -v sshd || echo /usr/sbin/sshd)

# 1. the gate itself
install -d -m 0755 /usr/local/sbin
if [ -f ./gpu-gate ]; then
  install -m 0755 ./gpu-gate /usr/local/sbin/gpu-gate
  echo "install: gate taken from the working directory"
else
  TMP=$(mktemp) || die "mktemp failed"
  curl -fsSL --retry 3 "$GATE_URL" -o "$TMP" || { rm -f "$TMP"; die "could not download the gate"; }
  # Refuse to install something that is not the script we expect.
  head -1 "$TMP" | grep -q '^#!/bin/sh' || { rm -f "$TMP"; die "downloaded file is not the gate"; }
  install -m 0755 "$TMP" /usr/local/sbin/gpu-gate
  rm -f "$TMP"
  echo "install: gate downloaded"
fi

# 2. the credentials it calls the verifier with
#    0644, not 0600: under ForceCommand the gate runs as the LOGIN user, which
#    must be able to read this. The token only authorises recording logins for
#    this one run, on a machine its tenant already controls.
install -d -m 0755 /etc/gpu-gateway
umask 022
cat > /etc/gpu-gateway/verify.env <<CONF
GPU_VERIFY_URL=$VERIFY_URL
GPU_RUN_TOKEN=$RUN_TOKEN
GPU_FAILMODE=$FAILMODE
CONF
chmod 0644 /etc/gpu-gateway/verify.env

# 3. the sshd drop-in that runs it
install -d -m 0755 /etc/ssh/sshd_config.d
cat > /etc/ssh/sshd_config.d/60-gpu-gate.conf <<'CONF'
# Installed by gpu-verified-image. Verifies interactive SSH logins.
# ExposeAuthInfo makes the authenticating key's line available to the gate as
# the file SSH_USER_AUTH points at, which is how it resolves the fingerprint.
ExposeAuthInfo yes
ForceCommand /usr/local/sbin/gpu-gate
CONF

# A drop-in is only read if sshd_config actually Includes that directory.
# Test for the Include line itself: `sshd -T` is not a probe for this, because
# it also fails for unrelated reasons such as absent host keys.
if ! grep -qE '^[[:space:]]*Include[[:space:]]+/etc/ssh/sshd_config\.d/\*\.conf' /etc/ssh/sshd_config 2>/dev/null; then
  rm -f /etc/ssh/sshd_config.d/60-gpu-gate.conf
  if ! grep -q '^ForceCommand /usr/local/sbin/gpu-gate' /etc/ssh/sshd_config; then
    printf '\nExposeAuthInfo yes\nForceCommand /usr/local/sbin/gpu-gate\n' >> /etc/ssh/sshd_config
    echo "install: sshd_config has no Include; appended the gate directly"
  fi
fi

# 4. validate BEFORE reloading. A ForceCommand sshd rejects would lock
#    everyone out, so a bad config is removed rather than applied.
#
#    sshd -t needs host keys to exist. A machine that has never started sshd
#    has none, and that is not a problem with our config: generate them first
#    so the check tests what it is meant to test.
ls /etc/ssh/ssh_host_*_key >/dev/null 2>&1 || ssh-keygen -A >/dev/null 2>&1

#    Likewise sshd's privilege-separation directory. The service creates it on
#    a host where sshd has run; on one where it has not, its absence would fail
#    the check for a reason unrelated to the gate.
[ -d /run/sshd ] || mkdir -p /run/sshd 2>/dev/null || true

if ! ERR=$("$SSHD" -t 2>&1); then
  rm -f /etc/ssh/sshd_config.d/60-gpu-gate.conf
  sed -i.gpugate-bak '/^ExposeAuthInfo yes$/d; /^ForceCommand \/usr\/local\/sbin\/gpu-gate$/d' \
    /etc/ssh/sshd_config 2>/dev/null || true
  die "sshd rejected the gate config, so it was removed rather than lock the machine: $ERR"
fi

systemctl reload ssh 2>/dev/null \
  || systemctl reload sshd 2>/dev/null \
  || service ssh reload 2>/dev/null \
  || service sshd reload 2>/dev/null \
  || kill -HUP "$(cat /var/run/sshd.pid 2>/dev/null)" 2>/dev/null \
  || echo "install: could not reload sshd automatically; reload it yourself"

echo "install: login gate active. Existing sessions are unaffected."
