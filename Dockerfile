# Verified-login GPU workload image.
#
# A CUDA runtime with sshd and a login gate that challenges every interactive
# SSH session with a one-time code. Built for hosts where the machine is a
# container and there is no post-boot hook to install the gate with: it is
# baked in here and wired up by the entrypoint from environment supplied at
# launch.
#
#   docker build -t ghcr.io/blackboxai-dev/gpu-verified:cuda12.4 .
#
# The entrypoint reads, from the container environment:
#   PUBLIC_KEY       the renter's SSH public key
#   GPU_VERIFY_URL   the verification endpoint
#   GPU_RUN_TOKEN    the per-run bearer token
#   GPU_FAILMODE     open | closed
FROM nvidia/cuda:12.4.1-runtime-ubuntu22.04

RUN apt-get update \
 && apt-get install -y --no-install-recommends openssh-server curl ca-certificates \
 && rm -rf /var/lib/apt/lists/* \
 && mkdir -p /var/run/sshd /etc/gpu-gateway /etc/ssh/sshd_config.d

COPY gpu-gate /usr/local/sbin/gpu-gate
COPY entrypoint.sh /usr/local/sbin/gpu-entrypoint
RUN chmod 0755 /usr/local/sbin/gpu-gate /usr/local/sbin/gpu-entrypoint

EXPOSE 22
ENTRYPOINT ["/usr/local/sbin/gpu-entrypoint"]

# Metadata last, so a changing revision never invalidates the layers above.
# REVISION, CREATED and DOCS_REF are supplied by CI; a local build leaves the
# first two empty rather than stamping a provenance it cannot vouch for.
ARG REVISION=""
ARG CREATED=""
ARG VERSION="cuda12.4"
ARG DOCS_REF="main"
LABEL org.opencontainers.image.title="Verified-login GPU image" \
      org.opencontainers.image.description="CUDA 12.4 runtime with sshd and a one-time-code SSH login gate, for GPU hosts that cannot run a post-boot hook." \
      org.opencontainers.image.source="https://github.com/blackboxai-dev/gpu-verified-image" \
      org.opencontainers.image.documentation="https://github.com/blackboxai-dev/gpu-verified-image/blob/$DOCS_REF/README.md" \
      org.opencontainers.image.vendor="Blackbox AI" \
      org.opencontainers.image.base.name="docker.io/nvidia/cuda:12.4.1-runtime-ubuntu22.04" \
      org.opencontainers.image.revision="$REVISION" \
      org.opencontainers.image.created="$CREATED" \
      org.opencontainers.image.version="$VERSION"
