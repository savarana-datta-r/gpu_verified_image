# Recorded-login GPU image, ML variant.
#
# The slim image (Dockerfile) carries the login gate and nothing else. This one
# adds the toolchain a Lambda Stack machine ships, so a renter who lands on it
# finds the tools they expect rather than a bare CUDA runtime.
#
# Differences from the slim image, all deliberate:
#   - a cudnn-devel base, so nvcc and the CUDA headers are present
#   - Python, and pip packages resolved at BUILD time, not pinned to a vendor's
#     frozen archive. Newer than Lambda ships, and not reproducible across
#     rebuilds: pin them here if that matters more than being current.
#
#   docker build -f Dockerfile.ml -t gpu-verified-image:ml .
# The base is pinned by digest, not by tag. `12.4.1-cudnn-devel-ubuntu22.04` is
# republished upstream, so building the same commit twice against the tag can
# produce two different images. Repin deliberately: resolve the tag, read
# docker-content-digest, and update the line below in its own commit.
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
 && mkdir -p /var/run/sshd /etc/gpu-gateway /etc/ssh/sshd_config.d

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

COPY gpu-gate /usr/local/sbin/gpu-gate
COPY entrypoint.sh /usr/local/sbin/gpu-entrypoint
RUN chmod 0755 /usr/local/sbin/gpu-gate /usr/local/sbin/gpu-entrypoint

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
 && printf 'PrintMotd yes\n' > /etc/ssh/sshd_config.d/10-motd.conf \
 && chmod 0644 /etc/ssh/sshd_config.d/10-motd.conf

EXPOSE 22 8888
ENTRYPOINT ["/usr/local/sbin/gpu-entrypoint"]

ARG REVISION=""
ARG CREATED=""
ARG VERSION="cuda12.4-ml"
ARG DOCS_REF="main"
LABEL org.opencontainers.image.title="Verified-login GPU image (ML)" \
      org.opencontainers.image.description="CUDA 12.4 devel with cuDNN, PyTorch, TensorFlow, JupyterLab and an SSH login gate that records each interactive login." \
      org.opencontainers.image.source="https://github.com/blackboxai-dev/gpu-verified-image" \
      org.opencontainers.image.documentation="https://github.com/blackboxai-dev/gpu-verified-image/blob/$DOCS_REF/README.md" \
      org.opencontainers.image.vendor="Blackbox AI" \
      org.opencontainers.image.base.name="docker.io/nvidia/cuda:12.4.1-cudnn-devel-ubuntu22.04" \
      org.opencontainers.image.revision="$REVISION" \
      org.opencontainers.image.created="$CREATED" \
      org.opencontainers.image.version="$VERSION"
