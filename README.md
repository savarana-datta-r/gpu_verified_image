# gpu-verified-image

Recorded SSH logins for rented GPUs.

Every interactive SSH session into a machine running this gate is reported to
the verifier as it opens, and the session continues. File transfers, remote
commands and editor sessions pass through untouched. The result is a record of
who actually logged in, rather than a record of who was given a key.

Nobody is asked for a code. The key `sshd` has already authenticated is the
factor; the verifier's part is to say who that key belongs to and write it
down.

```
ghcr.io/blackboxai-dev/gpu-verified-image:cuda12.4
```

## Two ways to use it

| Your machine is | Use | Why |
|---|---|---|
| a **container** (no post-boot hook) | [the image](#1-the-image) | nothing can run before the workload, so the gate has to be in the image. Needs Docker and the NVIDIA runtime on the host |
| a **VM or bare metal** (Lambda, your own box) | [the installer](#2-the-installer) | the machine already exists; drop the gate onto it and reload `sshd`. Needs only root, `sshd` and `curl` |

Both carry the same `gpu-gate` script and behave identically.

---

## 1. The image

Needs a host that can run containers with the GPU attached: Docker and the
NVIDIA Container Toolkit. Many GPU images ship both — Lambda Stack does. If
`docker: command not found`, either [install them](#installing-docker-and-the-nvidia-runtime)
or use [the installer](#2-the-installer) instead, which needs neither.

```sh
docker run -d --gpus all -p 2222:22 \
  -e PUBLIC_KEY="$(cat ~/.ssh/id_ed25519.pub)" \
  -e GPU_VERIFY_URL="https://your-verifier.example.com/verify" \
  -e GPU_RUN_TOKEN="…" \
  ghcr.io/blackboxai-dev/gpu-verified-image:cuda12.4

ssh -p 2222 root@localhost
```

### Authenticating to the registry

While the package is private, pulling needs a GitHub token with the
`read:packages` scope ([create one](https://github.com/settings/tokens)):

```sh
echo "$GITHUB_TOKEN" | docker login ghcr.io -u YOUR_GITHUB_USERNAME --password-stdin
```

With the `gh` CLI already signed in, `gh auth token` supplies it:

```sh
gh auth token | docker login ghcr.io -u YOUR_GITHUB_USERNAME --password-stdin
```

Once the package is public this step disappears and `docker run` works with
no credentials at all.

### Installing Docker and the NVIDIA runtime

Only if the host has neither. On Ubuntu:

```sh
curl -fsSL https://get.docker.com | sudo sh

curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey \
  | sudo gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg
curl -fsSL https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list \
  | sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#' \
  | sudo tee /etc/apt/sources.list.d/nvidia-container-toolkit.list
sudo apt-get update && sudo apt-get install -y nvidia-container-toolkit
sudo nvidia-ctk runtime configure --runtime=docker && sudo systemctl restart docker
```

Without `--gpus all` the container still runs; it just has no GPU.

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
FROM ghcr.io/blackboxai-dev/gpu-verified-image:cuda12.4
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
curl -fsSL https://raw.githubusercontent.com/blackboxai-dev/gpu-verified-image/main/install.sh \
  | sudo GPU_VERIFY_URL="https://your-verifier.example.com/verify" \
         GPU_RUN_TOKEN="…" \
         bash
```

Add `GPU_BANNER=1` to that environment to install the Blackbox welcome banner
at the same time; without it the machine's own MOTD is left alone.

Or, if you would rather read it first — which you should, before piping
anything to `sudo bash`:

```sh
git clone https://github.com/blackboxai-dev/gpu-verified-image
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
  - [ bash, -c, "curl -fsSL https://raw.githubusercontent.com/blackboxai-dev/gpu-verified-image/main/install.sh | GPU_VERIFY_URL=https://your-verifier.example.com/verify GPU_RUN_TOKEN=… bash" ]
```

---

## Branding

The image prints a Blackbox AI welcome banner on interactive login. It is
`motd` in this repository, installed to `/etc/motd` and `/etc/gpu-gateway/banner`.

Two paths print it, because neither covers both cases on its own. `sshd`'s
`PrintMotd` handles a plain shell session but never fires under a
`ForceCommand`, so with the gate active the gate prints the banner itself,
from `/etc/gpu-gateway/banner`. Only the image ships that file, so the
installer path leaves an existing machine's own MOTD alone.

Ubuntu's `update-motd.d` scripts and `/etc/legal` are removed, and `pam_motd`
is disabled, so the banner appears once with nothing above it. Commands,
`scp` and `sftp` print nothing at all.

The installer places the same banner by default, so a machine carrying the
gate looks the same however the gate got there. To leave a host's own MOTD
untouched:

```sh
sudo GPU_VERIFY_URL="…" GPU_RUN_TOKEN="…" GPU_BANNER=0 ./install.sh
```

`uninstall.sh` removes the banner along with everything else.

## Configuration

| Variable | Path | Required | Meaning |
|---|---|---|---|
| `GPU_VERIFY_URL` | both | yes | The verification endpoint. |
| `GPU_RUN_TOKEN` | both | yes | Bearer token for that endpoint, scoped to one machine run. |
| `GPU_FAILMODE` | both | no | `open` (default) or `closed`. See [Fail policy](#fail-policy). |
| `PUBLIC_KEY` | image | no | The renter's SSH public key, written to `/root/.ssh/authorized_keys`. Omit it if the host installs keys itself. |
| `GPU_BANNER` | installer | no | `0` skips the Blackbox welcome banner. On by default, as it is in the image. See [Branding](#branding). |

The image reads its values from the container environment at launch; the
installer reads them from the environment of the `install.sh` invocation.

### What the three required values are

**`GPU_VERIFY_URL`** is the HTTPS endpoint the gate reports each login to. The
gate holds no secret and decides nothing itself: it says which key opened a
session on which machine, and proceeds once the endpoint confirms it is
recorded. Any service implementing the single `POST` under
[The verifier API](#the-verifier-api) works. To try it with nothing to point
at, run [`demo-verifier.py`](#trying-it-without-a-backend) on the machine and
use `http://127.0.0.1:8080/verify`.

**`GPU_RUN_TOKEN`** is a bearer token that tells the verifier *which machine*
is calling. It is not a password you choose — whatever provisioned the
machine issues it, one per run, and the verifier recognises it. That is how
the record names the right person: the gate sends the fingerprint of the SSH
key that just authenticated, and the verifier maps it to the owner it
installed that key for. Without a token the verifier has no idea who is
calling and refuses.

**`GPU_FAILMODE`** decides what happens when the login **cannot be recorded** —
a timeout, a connection failure, a `5xx`. `open`, the default, lets the login
through with no record; `closed` refuses it. It never applies when the
verifier answers an explicit refusal, which is a denial under either setting.
See [Fail policy](#fail-policy).

Two more exist for mirrors and air-gapped installs, both installer-only and
rarely needed: `GATE_URL` and `BANNER_URL` override where the gate script and
the banner are fetched from. If a `gpu-gate` or `motd` file is present in the
working directory, it is used in preference to either.

No credentials are baked into the image. They arrive at launch.

---

## What happens on a login

The gate runs as an `sshd` `ForceCommand`: after authentication, on the
session's own terminal.

Only an interactive session is reported. Everything else passes through
untouched, because a transfer is not a login and `scp`, `sftp` and `rsync`
would break if the gate stood in their way.

| Session | Behaviour |
|---|---|
| `ssh host <command>` | runs the command verbatim, unreported |
| no TTY — sftp subsystem, `ssh -T` | hands off to `sftp-server`, unreported |
| a TTY and no command | **reported**, then execs the login shell |

The gate reads the fingerprint of the key `sshd` authenticated with (via
`ExposeAuthInfo`), tells the verifier a login opened, and proceeds as soon as
the verifier confirms it is recorded. The exchange adds one HTTP round trip to
the login and asks the person nothing.

A key the verifier does not recognise is still let through. `sshd` has already
authenticated it, and refusing would lock out a renter who added their own key
to a machine they are paying for. The verifier records it as unidentified
rather than naming the wrong person.

The gate logs to syslog under the tag `gpu-gate`.

### Fail policy

`GPU_FAILMODE` decides what happens when the login **cannot be recorded** — a
timeout, a connection failure, a 5xx, or a config too incomplete to call out
with.

| What happened | `open` (default) | `closed` |
|---|---|---|
| Verifier unreachable | login allowed, no record written | login refused |
| Verifier answered an explicit refusal | **refused** | **refused** |

`open` is the default because a control-plane blip should not lock a renter out
of a machine they are paying for. `closed` is for the case where a login that
cannot be recorded is worse than no login at all. Either way the machine notes
it in its own syslog.

---

## Checking it works

Run these after installing either way. They cover every behaviour described
above, and none of them need a verifier.

On the **image**, with the container published on port 2222:

```sh
# interactive login: the Blackbox banner, then a shell. No prompt
ssh -p 2222 root@localhost

# the GPU is visible inside the container (the driver is the host's)
ssh -p 2222 root@localhost 'nvidia-smi --query-gpu=name,driver_version --format=csv'

# a command passes through: no banner, no report, nothing but its own output
ssh -p 2222 root@localhost 'echo clean'

# so does a transfer
printf 'pwd\nbye\n' | sftp -q -P 2222 root@localhost

# runtime only, by design: none of these exist
ssh -p 2222 root@localhost 'which nvcc python3 jupyter || echo "none, as intended"'

# provenance: commit, build time, source repository, link to these docs
docker image inspect ghcr.io/blackboxai-dev/gpu-verified-image:cuda12.4 \
  --format '{{json .Config.Labels}}' | python3 -m json.tool
```

On the **installer**, against the host's own `sshd`. Keep your current
session open while you test, so a mistake cannot lock you out:

```sh
# the gate is loaded: both lines must appear
sudo sshd -T | grep -iE '^forcecommand|^exposeauthinfo'

# from a SECOND terminal, a fresh login is reported
ssh <user>@<host>

# a command is not
ssh <user>@<host> 'echo clean'

# the machine keeps whatever toolchain it had; the installer adds only the gate
ssh <user>@<host> 'which nvcc || echo "no nvcc on this host"'
```

On the **ML image**, everything above plus the toolchain. Run these over SSH
rather than with `docker exec`: the PATH a login shell gets is not the one
`docker exec` gets, and that difference has already hidden a bug here once.

```sh
# the compiler is on the PATH, not merely installed
ssh -p 2222 root@localhost 'nvcc --version | tail -2'

# both frameworks see the GPU through the container runtime
ssh -p 2222 root@localhost 'python3 -c "import torch; print(torch.__version__, torch.cuda.is_available())"'
ssh -p 2222 root@localhost 'python3 -c "import tensorflow as tf; print(len(tf.config.list_physical_devices(\"GPU\")))"'

# notebooks
ssh -p 2222 root@localhost 'which jupyter-lab'
```

To see a refusal rather than a pass, point `GPU_VERIFY_URL` at an unreachable
address with `GPU_FAILMODE=closed`: the login is denied with
`Login verification is unavailable and this machine is set to fail closed.`
With the default `open` the same login proceeds, unrecorded.

## The verifier API

The gate is not tied to any particular backend. Implement one `POST` call at
`GPU_VERIFY_URL` and it will work against your own service.

The request carries `Authorization: Bearer $GPU_RUN_TOKEN` and
`Content-Type: application/json`:

```json
{ "step": "request", "fingerprint": "SHA256:…", "osUser": "root", "sourceIp": "203.0.113.9" }
```

Answer `200` with `"verified": true` in the body and the login proceeds:

```json
{ "verified": true }
```

| Status | Meaning | Gate does |
|---|---|---|
| `200` with `"verified": true` | the login is recorded | opens the session |
| other `4xx` | an explicit refusal | refuses the login |
| `5xx` or no response | verifier unreachable | applies the fail policy |

The `step` field is sent for compatibility with verifiers that still implement
the older two-call handshake, where `request` issued a code and a second call
checked it. A verifier that answers the first call with the allow is never
asked again. A gate built against the older protocol receives `202` from such
a verifier and prompts, which is why both shapes are worth accepting if you
run a mixed fleet.

---

## Trying it without a backend

`demo-verifier.py` in this repository is a minimal verifier you can run on the
machine itself. It prints each login to its own terminal and answers the
allow, so the whole round trip is visible on one screen.

```sh
python3 demo-verifier.py            # listens on 127.0.0.1:8080
```

Then install the gate pointing at it:

```sh
sudo GPU_VERIFY_URL="http://127.0.0.1:8080/verify" \
     GPU_RUN_TOKEN="demo" GPU_FAILMODE=closed ./install.sh
```

Log in from a second terminal and watch the fingerprint, the OS user and the
source address appear in the verifier's output as the session opens. Demo
only: no key ownership, no persistence, no storage of any kind.

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

## What is in this repository

| File | |
|---|---|
| `Dockerfile` | the slim image |
| `Dockerfile.ml` | the ML image: the same gate, plus the toolchain |
| `entrypoint.sh` | PID 1 in the container: installs the key, writes the gate config, starts `sshd` |
| `gpu-gate` | the gate itself, run by `sshd` as a `ForceCommand`. Shared by both paths |
| `install.sh` | puts the gate on a machine that already exists |
| `uninstall.sh` | takes it off again |
| `motd`, `issue` | the Blackbox welcome banner |
| `demo-verifier.py` | a minimal verifier for trying it without a backend |
| `.github/workflows/publish.yml` | build, scan and publish to GHCR |

## Two images

The slim image carries the gate and nothing else. The ML image adds the
toolchain a Lambda Stack machine ships, for a renter who expects to find one.

| | `cuda12.4` | `cuda12.4-ml` |
|---|---|---|
| Base | `12.4.1-runtime` | `12.4.1-cudnn-devel` |
| Size | about 1.5 GB | about 15 GB |
| Compiler | none | `nvcc`, CUDA headers, cuDNN |
| Python | none | 3, with pip upgraded first |
| Frameworks | none | PyTorch, torchvision, torchaudio, TensorFlow |
| Science stack | none | NumPy, SciPy, pandas, matplotlib, scikit-learn |
| Notebooks | none | JupyterLab, port 8888 |
| Login gate | yes | yes, identical |

Reach for the slim one when the workload brings its own image, and the ML one
when the machine is the workspace.

One deliberate difference: the ML image resolves its pip packages at build
time rather than pinning them, so it ships current versions rather than a
vendor's frozen set. Two rebuilds a month apart will not be identical. The
slim image has no such packages and stays reproducible.

That has one consequence worth knowing. pip resolves torch to the newest
build, which currently carries CUDA 13 libraries, while the base image and
`nvcc` are CUDA 12.4. It works — torch bundles its own CUDA runtime and does
not use the system one — but the compiler and the framework are on different
CUDA versions. Install torch from a `cu124` index if you need them to match.

Verified on a live RunPod RTX 3090: torch and TensorFlow both see the GPU,
`nvcc` reports 12.4, and the gate challenges an interactive login as it does
on the slim image.

## Tags

| Tag | |
|---|---|
| `cuda12.4` | current slim build |
| `latest` | same as above |
| `cuda12.4-ml`, `ml` | current ML build |
| `<commit sha>` | one exact, immutable slim build — pin this where reproducibility matters |

Every image carries its commit, build time, source repository and a link to
these docs in its OCI labels:

```sh
docker buildx imagetools inspect ghcr.io/blackboxai-dev/gpu-verified-image:cuda12.4 \
  --format '{{json .Image}}'
```

## Building it yourself

```sh
docker build -t gpu-verified:local .
```

CI builds, scans and publishes on any change to the `Dockerfile`, the
entrypoint or the gate. Trivy reports HIGH and CRITICAL findings on every
build without blocking the push.
