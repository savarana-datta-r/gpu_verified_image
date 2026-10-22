# gpu-verified-image

GPU workload images with sshd and the Blackbox login banner.

**This branch has no login gate.** A key holder goes straight in. The gated
build, which reports each interactive login to the gateway, is the
[`image_otp`](../../tree/image_otp) branch, published under the `-otp` tags.

```
ghcr.io/blackboxai-dev/gpu-verified-image:cuda12.4        # CUDA runtime
ghcr.io/blackboxai-dev/gpu-verified-image:cuda12.4-ml     # the above plus a toolchain
```

`:latest` tracks `:cuda12.4`, and `:ml` is an alias for `:cuda12.4-ml`.

## Which tag

| Tag | Base | Contents |
|---|---|---|
| `cuda12.4` | `nvidia/cuda:12.4.1-runtime-ubuntu22.04` | sshd, curl, the banner. Runtime only: no compiler, no frameworks |
| `cuda12.4-ml` | `nvidia/cuda:12.4.1-cudnn-devel-ubuntu22.04` | the above plus `nvcc`, PyTorch, TensorFlow and JupyterLab |

The ML image is roughly ten times the size, so pick the runtime image unless
the workload needs the toolchain.

## Running it

The container needs the renter's public key and the host's NVIDIA runtime:

```sh
docker run -d --gpus all -p 2222:22 \
  -e PUBLIC_KEY="$(cat ~/.ssh/id_ed25519.pub)" \
  ghcr.io/blackboxai-dev/gpu-verified-image:cuda12.4

ssh -p 2222 root@localhost
```

The login is `root`. The driver comes from the host, so `--gpus all` and the
NVIDIA container runtime are required for `nvidia-smi` to work inside.

### Environment

| Variable | Required | Purpose |
|---|---|---|
| `PUBLIC_KEY` | yes | the SSH public key written to `/root/.ssh/authorized_keys`. May carry several keys, one per line |
| `PUBLIC_KEYS` | no | read alongside `PUBLIC_KEY` and merged with it, for callers that reach for the plural. Duplicates are collapsed |
| `BLACKBOX_HOST` | no | hostname shown on the banner; defaults to the container's |
| `BLACKBOX_GPU` | no | GPU label shown on the banner; the renderer reads it from `nvidia-smi` when unset |
| `BLACKBOX_LOGIN` | no | login name shown on the banner; defaults to `root` |

Without `PUBLIC_KEY` the container still starts, and nobody can log in.

### Authenticating to the registry

The package is public. A pull needs no credentials; pushing needs a token with
`write:packages`:

```sh
echo "$GITHUB_TOKEN" | docker login ghcr.io -u "$GITHUB_USER" --password-stdin
```

## The banner

`pam_motd` prints it when the session opens, before any command, so it shows
for a shell and for a remote command alike. The entrypoint renders it at boot
with the machine's host, GPU and login beside the Blackbox mark; the static
`/etc/motd` baked into the image is the fallback if rendering fails.

Ubuntu's own `update-motd.d` scripts are removed during the build, so the
distribution banner does not print above ours.

## Checking it works

```sh
# the banner, then a shell — no prompt, no verification
ssh -p 2222 root@localhost

# readiness, rather than polling the SSH port and guessing
docker inspect --format '{{.State.Health.Status}}' <container>

# the GPU is visible inside the container (the driver is the host's)
ssh -p 2222 root@localhost nvidia-smi

# a remote command returns its own output and nothing else
ssh -p 2222 root@localhost 'echo ok'

# runtime image only, by design: none of these exist
ssh -p 2222 root@localhost 'command -v nvcc || echo "no compiler, as expected"'

# provenance: commit, build time, source repository, link to these docs
docker inspect --format '{{json .Config.Labels}}' \
  ghcr.io/blackboxai-dev/gpu-verified-image:cuda12.4 | jq
```

On the ML image:

```sh
# the compiler is on the PATH, not merely installed
ssh -p 2222 root@localhost 'nvcc --version'

# both frameworks see the GPU through the container runtime
ssh -p 2222 root@localhost 'python3 -c "import torch; print(torch.cuda.is_available())"'

# notebooks
ssh -p 2222 root@localhost 'command -v jupyter'
```

## Building

```sh
docker build -t ghcr.io/blackboxai-dev/gpu-verified-image:cuda12.4    -f Dockerfile    .
docker build -t ghcr.io/blackboxai-dev/gpu-verified-image:cuda12.4-ml -f Dockerfile.ml .
```

CI supplies `REVISION` and `CREATED` as build arguments. A local build leaves
them empty rather than stamping a provenance it cannot vouch for. The bases are
pinned by digest, so the same commit rebuilds to the same image; repin by
resolving the tag and updating the `FROM` line in its own commit.

After publishing, CI pulls the immutable commit-sha tag back and compares the
files inside it with the files in the tree, so a build cannot quietly ship
something other than what was committed.

Pushing to this branch republishes `cuda12.4`, `cuda12.4-ml`, `ml` and
`latest`. Pushing to `image_otp` republishes the same names with `-otp`.

## Limits

The image is not a security boundary. Whoever holds the key has root inside
the container, and root inside the container can change anything in it. The
image provides a usable machine and a consistent login banner; it does not
confine the person logging in.

Logins are **not** recorded on this branch — nothing watches them. Use the
`image_otp` build where a per-login record is needed.
