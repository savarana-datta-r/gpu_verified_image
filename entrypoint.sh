#!/bin/sh
# Wire the renter's key and the login banner, then run sshd in the foreground
# as PID 1. Everything here is what cloud-init does on the VM providers,
# compressed into a container start.
#
# NO LOGIN VERIFICATION on this branch. The gated build lives on image_otp and
# publishes as :cuda12.4-otp / :ml-otp; this one lets a key holder straight in.
set -u

# 1. the renter's key -> root's authorized_keys (RunPod/Vast convention)
# Either variable may carry SEVERAL keys, one per line, so a launch can admit
# a person and a CI runner without a second machine. PUBLIC_KEY is the name
# RunPod and Vast both use and stays the primary; PUBLIC_KEYS is the plural
# spelling people reach for. Both are read and duplicates are collapsed.
if [ -n "${PUBLIC_KEY:-}" ] || [ -n "${PUBLIC_KEYS:-}" ]; then
  mkdir -p /root/.ssh && chmod 700 /root/.ssh
  printf '%s\n%s\n' "${PUBLIC_KEY:-}" "${PUBLIC_KEYS:-}" \
    | grep -v '^[[:space:]]*$' \
    | awk '!seen[$0]++' > /root/.ssh/authorized_keys
  chmod 600 /root/.ssh/authorized_keys
  echo "gpu-entrypoint: $(wc -l < /root/.ssh/authorized_keys | tr -d ' ') authorized key(s) installed" >&2
fi

# 2. the login banner, rendered from what this launch knows.
#    The static /etc/motd baked at build time is the fallback; this overwrites
#    it with the machine's real host, GPU and login.
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

# 3. host keys, if the image was built without them
# The image ships none: a baked set means every machine from that image has the
# same host identity, and the private half is in the image anyone can pull.
# ssh-keygen -A writes only the types that are absent.
ssh-keygen -A >/dev/null 2>&1
if [ ! -f /etc/ssh/ssh_host_ed25519_key ]; then
  echo "gpu-entrypoint: could not generate SSH host keys; sshd will refuse to start" >&2
fi

exec /usr/sbin/sshd -D -e
