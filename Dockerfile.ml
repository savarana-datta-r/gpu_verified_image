# Blackbox GPU workload image.
#
# A CUDA runtime with sshd and the Blackbox login banner. NO LOGIN GATE: a
# key holder goes straight in. The gated build - which reports every
# interactive login to the gateway - is the image_otp branch, published as
# :cuda12.4-otp and :ml-otp.
#
#   docker build -t ghcr.io/blackboxai-dev/gpu-verified-image:cuda12.4-ml -f Dockerfile.ml .
#
# The entrypoint reads, from the container environment:
#   PUBLIC_KEY       the renter's SSH public key
#   BLACKBOX_HOST    hostname for the banner   (optional)
#   BLACKBOX_GPU     GPU label for the banner  (optional)
#   BLACKBOX_LOGIN   login name for the banner (optional)
# The base is pinned by digest, not by tag. `12.4.1-cudnn-devel-ubuntu22.04` is republished upstream, so
# building the same commit twice against the tag can produce two different
# images. Repin deliberately: resolve the tag, read docker-content-digest, and
# update the line below in its own commit.
FROM nvidia/cuda:12.4.1-cudnn-devel-ubuntu22.04@sha256:622e78a1d02c0f90ed900e3985d6c975d8e2dc9ee5e61643aed587dcf9129f42

ENV DEBIAN_FRONTEND=noninteractive
ENV PIP_NO_CACHE_DIR=1
ENV PIP_ROOT_USER_ACTION=ignore

RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      openssh-server curl ca-certificates \
      python3 python3-dev python3-pip python3-venv \
      git build-essential pkg-config \
 && rm -rf /var/lib/apt/lists/* \
 && mkdir -p /var/run/sshd /etc/ssh/sshd_config.d

# pip itself first, so the resolver below is the current one.
RUN python3 -m pip install --upgrade pip setuptools wheel

# The frameworks. Separate layers so a change to one does not re-download the
# other; torch is the larger of the two by some margin.
RUN python3 -m pip install torch torchvision torchaudio
RUN python3 -m pip install tensorflow

# The rest of what a Lambda Stack box has on it.
RUN python3 -m pip install \
      numpy scipy pandas matplotlib scikit-learn \
      jupyterlab notebook ipywidgets

# Docker's ENV does not reach an sshd login shell, and SSH is how anyone uses
# this image: without this, nvcc is installed but "command not found". A
# profile script is read by the login shell the gate hands over to.
RUN printf '%s\n' \
      'export CUDA_HOME=/usr/local/cuda' \
      'export PATH=/usr/local/cuda/bin:$PATH' \
      'export LD_LIBRARY_PATH=/usr/local/cuda/lib64${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}' \
      > /etc/profile.d/10-cuda.sh \
 && chmod 0644 /etc/profile.d/10-cuda.sh

COPY entrypoint.sh /usr/local/sbin/gpu-entrypoint
RUN chmod 0755 /usr/local/sbin/gpu-entrypoint

# The banner renderer. The static motd below is the build-time fallback; the
# entrypoint overwrites /etc/motd with the rendered one, which carries the
# machine's host, GPU and login beside the mark.
COPY render-motd.sh /etc/blackbox/render-motd.sh
COPY motd /etc/motd
COPY issue /etc/issue
RUN chmod 0755 /etc/blackbox/render-motd.sh \
 && chmod 0644 /etc/motd /etc/issue \
 && rm -f /etc/update-motd.d/* /etc/legal \
 && printf 'PrintMotd yes\n' > /etc/ssh/sshd_config.d/10-motd.conf \
 && chmod 0644 /etc/ssh/sshd_config.d/10-motd.conf

EXPOSE 22 8888

# Readiness. A launcher otherwise has to poll the SSH port blindly and guess
# whether a refused connection means "still pulling" or "never coming up".
# `sshd -t` checks the configuration; ssh-keyscan is what says it is actually
# serving, since it completes a protocol handshake rather than only opening a
# socket. Exec form with an explicit interpreter: the shell form runs under
# /bin/sh, which is dash here, and a bash-only probe such as /dev/tcp fails on
# every check. start-period covers the entrypoint writing host keys on a machine
# whose image was built without them.
HEALTHCHECK --interval=10s --timeout=5s --start-period=120s --retries=60 \
  CMD ["/bin/sh", "-c", "/usr/sbin/sshd -t && ssh-keyscan -T 3 -p 22 127.0.0.1 >/dev/null 2>&1"]
ENTRYPOINT ["/usr/local/sbin/gpu-entrypoint"]

ARG REVISION=""
ARG CREATED=""
ARG VERSION="cuda12.4-ml"
ARG DOCS_REF="main"
LABEL org.opencontainers.image.title="Verified-login GPU image (ML)" \
      org.opencontainers.image.description="CUDA 12.4 devel with cuDNN, PyTorch, TensorFlow, JupyterLab and a one-time-code SSH login gate." \
      org.opencontainers.image.source="https://github.com/blackboxai-dev/gpu-verified-image" \
      org.opencontainers.image.documentation="https://github.com/blackboxai-dev/gpu-verified-image/blob/$DOCS_REF/README.md" \
      org.opencontainers.image.vendor="Blackbox AI" \
      org.opencontainers.image.base.name="docker.io/nvidia/cuda:12.4.1-cudnn-devel-ubuntu22.04" \
      org.opencontainers.image.revision="$REVISION" \
      org.opencontainers.image.created="$CREATED" \
      org.opencontainers.image.version="$VERSION"
