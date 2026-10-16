# gpu-verified-image

Verified SSH logins for rented GPUs.

Every interactive SSH session into a machine running this gate is challenged
with a one-time code. File transfers, remote commands and editor sessions pass
through untouched. The result is a record of who actually logged in, rather
than a record of who was given a key.

```
ghcr.io/savarana-datta-r/gpu-verified-image:cuda12.4
```

## Two ways to use it

| Your machine is | Use | Why |
|---|---|---|
| a **container** (no post-boot hook) | [the image](#1-the-image) | nothing can run before the workload, so the gate has to be in the image |
| a **VM or bare metal** (Lambda, your own box) | [the installer](#2-the-installer) | the machine already exists; drop the gate onto it and reload `sshd` |

Both carry the same `gpu-gate` script and behave identically.

---

## 1. The image

```sh
docker run -d --gpus all -p 2222:22 \
  -e PUBLIC_KEY="$(cat ~/.ssh/id_ed25519.pub)" \
  -e GPU_VERIFY_URL="https://your-verifier.example.com/verify" \
  -e GPU_RUN_TOKEN="…" \
  ghcr.io/savarana-datta-r/gpu-verified-image:cuda12.4

ssh -p 2222 root@localhost
```

The image is public; no registry login is needed.

Leave `GPU_VERIFY_URL` and `GPU_RUN_TOKEN` unset and you get an ordinary
SSH-capable CUDA container with no gate — useful for checking the plumbing
before you wire up verification.

### On a GPU provider

Most container providers take an image reference and a set of environment
variables on the launch call. Point the image at this reference and pass the
four variables below. `PUBLIC_KEY` is the convention most of them already use
to install the renter's key.

### What is in it

| | |
|---|---|
| Base | `nvidia/cuda:12.4.1-runtime-ubuntu22.04` |
| Added | `openssh-server`, `curl`, `ca-certificates` |
| Entrypoint | `/usr/local/sbin/gpu-entrypoint` (PID 1) |
| Gate | `/usr/local/sbin/gpu-gate` |
| Port | 22 |
| User | `root` |

Nothing else. There is **no** CUDA compiler, no Python, no PyTorch and no
Jupyter — this is the `runtime` base, not `devel`. The image exists to carry
the gate. A workload that needs a toolchain should build on top of it:

```dockerfile
FROM ghcr.io/savarana-datta-r/gpu-verified-image:cuda12.4
RUN apt-get update && apt-get install -y --no-install-recommends python3-pip \
 && rm -rf /var/lib/apt/lists/*
```

Keep the `ENTRYPOINT` as it is, or the gate will not be wired up at start.

The GPU driver comes from the host through the container runtime, as with any
CUDA container.

---

## 2. The installer

For a GPU machine that already exists. Needs root, `sshd`, and `curl`.

```sh
curl -fsSL https://raw.githubusercontent.com/savarana-datta-r/gpu_verified_image/main/install.sh \
  | sudo GPU_VERIFY_URL="https://your-verifier.example.com/verify" \
         GPU_RUN_TOKEN="…" \
         bash
```

Or, if you would rather read it first — which you should, before piping
anything to `sudo bash`:

```sh
git clone https://github.com/savarana-datta-r/gpu_verified_image
cd gpu-verified-image
sudo GPU_VERIFY_URL="…" GPU_RUN_TOKEN="…" ./install.sh
```

It writes three files, validates the configuration with `sshd -t`, and reloads
`sshd`. Existing sessions are not dropped. Running it twice changes nothing.

| Path | Mode | |
|---|---|---|
| `/usr/local/sbin/gpu-gate` | `0755` | the gate |
| `/etc/gpu-gateway/verify.env` | `0644` | the credentials it calls with |
| `/etc/ssh/sshd_config.d/60-gpu-gate.conf` | `0644` | the drop-in that runs it |

`verify.env` is `0644` rather than `0600` because under `ForceCommand` the
gate runs as the **login user**, not as root, and must be able to read it. The
token authorises recording logins for one run, on a machine its tenant already
controls.

To remove it:

```sh
sudo ./uninstall.sh
```

### Via cloud-init

On a provider that takes a boot script, the same installer works at first boot:

```yaml
#cloud-config
runcmd:
  - [ bash, -c, "curl -fsSL https://raw.githubusercontent.com/savarana-datta-r/gpu_verified_image/main/install.sh | GPU_VERIFY_URL=https://your-verifier.example.com/verify GPU_RUN_TOKEN=… bash" ]
```

---

## Configuration

Both paths read the same four values.

| Variable | Required | Meaning |
|---|---|---|
| `PUBLIC_KEY` | image only | The renter's SSH public key, written to `/root/.ssh/authorized_keys`. Omit it if the host installs keys itself. |
| `GPU_VERIFY_URL` | yes | The verification endpoint. |
| `GPU_RUN_TOKEN` | yes | Bearer token for that endpoint, scoped to one machine run. |
| `GPU_FAILMODE` | no | `open` (default) or `closed`. See [Fail policy](#fail-policy). |

No credentials are baked into the image. They arrive at launch.

---

## What happens on a login

The gate runs as an `sshd` `ForceCommand`: after authentication, on the
session's own terminal. That is why it can prompt at all — a PAM module
cannot.

Only an interactive shell is challenged. Everything else passes through,
because `scp`, `sftp`, `rsync` and editor remotes cannot answer a prompt and
gating them would break every transfer.

| Session | Behaviour |
|---|---|
| `ssh host <command>` | runs the command verbatim |
| no TTY — sftp subsystem, `ssh -T` | hands off to `sftp-server` |
| a TTY and no command | **challenged**, then execs the login shell |

A challenged login gets three attempts. The gate reads the fingerprint of the
key `sshd` authenticated with (via `ExposeAuthInfo`), asks the verifier to
issue a code to that key's owner, and prompts for it.

The gate logs to syslog under the tag `gpu-gate`.

### Fail policy

`GPU_FAILMODE` applies **only** when the verifier cannot be reached — a
timeout, a connection failure, a 5xx. It is never applied when the verifier
answers and says no.

| What happened | `open` (default) | `closed` |
|---|---|---|
| Verifier unreachable | login allowed, recorded unverified | login refused |
| Verifier answered "no" | **refused** | **refused** |

A wrong code is never a network problem. Conflating the two would mean the
default policy waved through every incorrect code.

---

## The verifier API

The gate is not tied to any particular backend. Implement two `POST` calls at
`GPU_VERIFY_URL` and it will work against your own service.

Both requests carry `Authorization: Bearer $GPU_RUN_TOKEN` and
`Content-Type: application/json`.

**Step 1 — request a code**

```json
{ "step": "request", "fingerprint": "SHA256:…", "osUser": "root", "sourceIp": "203.0.113.9" }
```

| Status | Meaning | Gate does |
|---|---|---|
| `202` | code issued | prompts for it |
| `429` | a code was issued moments ago and is still valid | prompts for it, without resending |
| other `4xx` | cannot verify this key (for example, no owner to notify) | applies the fail policy |
| `5xx` or no response | verifier unreachable | applies the fail policy |

**Step 2 — verify the code**

```json
{ "step": "verify", "fingerprint": "SHA256:…", "code": "123456", "osUser": "root", "sourceIp": "203.0.113.9" }
```

Respond with `"verified": true` in the body to admit the login. Anything else
is a denial, and the gate re-prompts until three attempts are spent.

---

## Guarantees and limits

**A broken gate never locks anyone out.** Both paths validate the generated
configuration with `sshd -t` before applying it, and discard the gate if
`sshd` rejects it. A failed install degrades to an unverified machine; it
never produces a machine nobody can log into.

**It is not a security boundary.** Whoever rents the machine has root. They
can delete the drop-in, reload `sshd`, and log in unchallenged. The gate
verifies and records who logs in; it does not confine them. Treat it as
accountability, not access control.

**A container keeps no login history of its own.** There is no journal inside
one: `sshd` writes to the entrypoint's output, so `auth.log` does not exist
and `last` returns nothing. The gate can challenge a login but cannot
passively record one. On a VM, the system journal gives you that second
record; in a container, your verifier's own logs are the record.

---

## Tags

| Tag | |
|---|---|
| `cuda12.4` | current build for this CUDA base |
| `latest` | same as above |
| `<commit sha>` | one exact, immutable build — pin this where reproducibility matters |

Every image carries its commit, build time, source repository and a link to
these docs in its OCI labels:

```sh
docker buildx imagetools inspect ghcr.io/savarana-datta-r/gpu-verified-image:cuda12.4 \
  --format '{{json .Image}}'
```

## Building it yourself

```sh
docker build -t gpu-verified:local .
```

CI builds, scans and publishes on any change to the `Dockerfile`, the
entrypoint or the gate. Trivy reports HIGH and CRITICAL findings on every
build without blocking the push.
