# Recorded-login GPU workload image.
#
# A CUDA runtime with sshd and a login gate that reports every interactive SSH
# session to the gateway as it opens. No code is asked for. Built for hosts
# where the machine is a container and there is no post-boot hook to install
# the gate with: it is baked in here and wired up by the entrypoint from
# environment supplied at launch.
#
#   docker build -t ghcr.io/blackboxai-dev/gpu-verified-image:cuda12.4 .
#
# The entrypoint reads, from the container environment:
#   PUBLIC_KEY       the renter's SSH public key
#   GPU_VERIFY_URL   the verification endpoint
#   GPU_RUN_TOKEN    the per-run bearer token
#   GPU_FAILMODE     open | closed
# The base is pinned by digest, not by tag. `12.4.1-runtime-ubuntu22.04` is
# republished upstream, so building the same commit twice against the tag can
# produce two different images. Repin deliberately: resolve the tag, read
# docker-content-digest, and update the line below in its own commit.
FROM nvidia/cuda:12.4.1-runtime-ubuntu22.04@sha256:517da2300c184c9999ec203c2665244bdebd3578d12fcc7065e83667932643d9

RUN apt-get update \
 && apt-get install -y --no-install-recommends openssh-server curl ca-certificates \
 && rm -rf /var/lib/apt/lists/* \
 && mkdir -p /var/run/sshd /etc/gpu-gateway /etc/ssh/sshd_config.d

COPY gpu-gate /usr/local/sbin/gpu-gate
COPY entrypoint.sh /usr/local/sbin/gpu-entrypoint
RUN chmod 0755 /usr/local/sbin/gpu-gate /usr/local/sbin/gpu-entrypoint

# Branding.
#
# pam_motd prints it, not sshd's PrintMotd. PrintMotd fires only for a plain
# shell session, and the login gate is a ForceCommand, which sshd treats as a
# command execution — so with the gate on, PrintMotd prints nothing at all.
# pam_motd runs when the session opens, before any command, so the banner
# shows either way. PrintMotd is left off so it is never printed twice.
#
# Ubuntu's own update-motd.d scripts are removed: they print the distribution
# banner above ours, which is the provider branding this replaces.
# The banner renderer. The static motd below is the build-time fallback; the
# entrypoint overwrites /etc/motd with the rendered one, which carries the
# machine's host, GPU and login beside the mark.
COPY render-motd.sh /etc/blackbox/render-motd.sh
COPY motd /etc/motd
COPY motd /etc/gpu-gateway/banner
COPY issue /etc/issue
RUN chmod 0755 /etc/blackbox/render-motd.sh \
 && chmod 0644 /etc/motd /etc/gpu-gateway/banner /etc/issue \
 && rm -f /etc/update-motd.d/* /etc/legal \
 && sed -i 's/^\(session .*pam_motd\.so.*\)$/# \1/' /etc/pam.d/sshd \
 && printf 'PrintMotd yes\n' > /etc/ssh/sshd_config.d/10-motd.conf \
 && chmod 0644 /etc/ssh/sshd_config.d/10-motd.conf

EXPOSE 22

# Readiness. A launcher otherwise has to poll the SSH port blindly and guess
# whether a refused connection means "still pulling" or "never coming up".
# `sshd -t` checks the configuration; ssh-keyscan is what says it is actually
# serving, since it completes a protocol handshake rather than only opening a
# socket. Exec form with an explicit interpreter: the shell form runs under
# /bin/sh, which is dash here, and a bash-only probe such as /dev/tcp fails on
# every check. start-period covers the entrypoint writing host keys on a
# machine whose image was built without them.
HEALTHCHECK --interval=10s --timeout=5s --start-period=60s --retries=30 \
  CMD ["/bin/sh", "-c", "/usr/sbin/sshd -t && ssh-keyscan -T 3 -p 22 127.0.0.1 >/dev/null 2>&1"]

ENTRYPOINT ["/usr/local/sbin/gpu-entrypoint"]

# Metadata last, so a changing revision never invalidates the layers above.
# REVISION, CREATED and DOCS_REF are supplied by CI; a local build leaves the
# first two empty rather than stamping a provenance it cannot vouch for.
ARG REVISION=""
ARG CREATED=""
ARG VERSION="cuda12.4"
ARG DOCS_REF="main"
LABEL org.opencontainers.image.title="Verified-login GPU image" \
      org.opencontainers.image.description="CUDA 12.4 runtime with sshd and an SSH login gate that records each interactive login, for GPU hosts that cannot run a post-boot hook." \
      org.opencontainers.image.source="https://github.com/blackboxai-dev/gpu-verified-image" \
      org.opencontainers.image.documentation="https://github.com/blackboxai-dev/gpu-verified-image/blob/$DOCS_REF/README.md" \
      org.opencontainers.image.vendor="Blackbox AI" \
      org.opencontainers.image.base.name="docker.io/nvidia/cuda:12.4.1-runtime-ubuntu22.04" \
      org.opencontainers.image.revision="$REVISION" \
      org.opencontainers.image.created="$CREATED" \
      org.opencontainers.image.version="$VERSION"
