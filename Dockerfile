# Blackbox GPU workload image.
#
# A CUDA runtime with sshd and the Blackbox login banner. NO LOGIN GATE: a
# key holder goes straight in. The gated build - which reports every
# interactive login to the gateway - is the image_otp branch, published as
# :cuda12.4-otp and :ml-otp.
#
#   docker build -t ghcr.io/blackboxai-dev/gpu-verified-image:cuda12.4 -f Dockerfile .
#
# The entrypoint reads, from the container environment:
#   PUBLIC_KEY       the renter's SSH public key
#   BLACKBOX_HOST    hostname for the banner   (optional)
#   BLACKBOX_GPU     GPU label for the banner  (optional)
#   BLACKBOX_LOGIN   login name for the banner (optional)
# The base is pinned by digest, not by tag. `12.4.1-runtime-ubuntu22.04` is republished upstream, so
# building the same commit twice against the tag can produce two different
# images. Repin deliberately: resolve the tag, read docker-content-digest, and
# update the line below in its own commit.
FROM nvidia/cuda:12.4.1-runtime-ubuntu22.04@sha256:517da2300c184c9999ec203c2665244bdebd3578d12fcc7065e83667932643d9

RUN apt-get update \
 && apt-get install -y --no-install-recommends openssh-server curl ca-certificates \
 && rm -rf /var/lib/apt/lists/* \
 && mkdir -p /var/run/sshd /etc/ssh/sshd_config.d

COPY entrypoint.sh /usr/local/sbin/gpu-entrypoint
RUN chmod 0755 /usr/local/sbin/gpu-entrypoint

# Branding.
#
# pam_motd prints it when the session opens, before any command, so the banner
# shows for a shell and for a remote command alike.
#
# Ubuntu's own update-motd.d scripts are removed: they print the distribution
# banner above ours, which is the provider branding this replaces.
# The banner renderer. The static motd below is the build-time fallback; the
# entrypoint overwrites /etc/motd with the rendered one, which carries the
# machine's host, GPU and login beside the mark.
COPY render-motd.sh /etc/blackbox/render-motd.sh
COPY motd /etc/motd
COPY issue /etc/issue
RUN chmod 0755 /etc/blackbox/render-motd.sh \
 && chmod 0644 /etc/motd /etc/issue \
 && rm -f /etc/update-motd.d/* /etc/legal \
 && sed -i 's/^\(session .*pam_motd\.so.*\)$/# \1/' /etc/pam.d/sshd \
 && printf 'PrintMotd yes\n' > /etc/ssh/sshd_config.d/10-motd.conf \
 && chmod 0644 /etc/ssh/sshd_config.d/10-motd.conf

EXPOSE 22

# Readiness. A launcher otherwise has to poll the SSH port blindly and guess
# whether a refused connection means "still pulling" or "never coming up".
# `sshd -t` checks the configuration; the port check is what says it is
# listening. start-period covers the entrypoint writing host keys on a machine
# whose image was built without them.
HEALTHCHECK --interval=10s --timeout=5s --start-period=60s --retries=30 \
  CMD /usr/sbin/sshd -t && (exec 3<>/dev/tcp/127.0.0.1/22) || exit 1
ENTRYPOINT ["/usr/local/sbin/gpu-entrypoint"]

# Metadata last, so a changing revision never invalidates the layers above.
# REVISION, CREATED and DOCS_REF are supplied by CI; a local build leaves the
# first two empty rather than stamping a provenance it cannot vouch for.
ARG REVISION=""
ARG CREATED=""
ARG VERSION="cuda12.4"
ARG DOCS_REF="main"
LABEL org.opencontainers.image.title="Verified-login GPU image" \
      org.opencontainers.image.description="CUDA 12.4 runtime with sshd and the Blackbox login banner. No login verification; see the image_otp branch for the gated build." \
      org.opencontainers.image.source="https://github.com/blackboxai-dev/gpu-verified-image" \
      org.opencontainers.image.documentation="https://github.com/blackboxai-dev/gpu-verified-image/blob/$DOCS_REF/README.md" \
      org.opencontainers.image.vendor="Blackbox AI" \
      org.opencontainers.image.base.name="docker.io/nvidia/cuda:12.4.1-runtime-ubuntu22.04" \
      org.opencontainers.image.revision="$REVISION" \
      org.opencontainers.image.created="$CREATED" \
      org.opencontainers.image.version="$VERSION"
