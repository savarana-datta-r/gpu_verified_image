# gpu-verified-image — two-factor branch

A CUDA image with `sshd` and a login gate that asks for a code from an
authenticator app before it hands over a shell.

The code is checked **on the machine**. There is no gateway, no network call and
no email anywhere in the login path, so this image runs unchanged on any
provider — RunPod, Vast, Lambda, a box under a desk — and keeps working when
your control plane is down.

## What it protects, and what it does not

**It protects against a stolen SSH key.** Whoever holds the key must also hold
the enrolled authenticator device. That is the entire claim, and it is worth
making: keys leak into dotfiles, CI logs, old laptops and shared machines, and
on their own they are a single factor.

**It is not a boundary against the person renting the machine.** They have root.
They can read the secret out of `/etc/gpu-gateway/totp.env`, delete the
`ForceCommand` line from the SSH configuration, and log in unchallenged for the
rest of the run. Nothing in an image can hold against its own administrator, and
a product claiming otherwise is describing something it cannot deliver.

**It keeps no record of who logged in.** Nothing is reported anywhere, because
there is nobody to report to. A container has no system journal either, so the
login history effectively does not exist. This is authentication, not audit — a
deliberate trade for working without infrastructure. If you need the record, use
the gateway-backed image on the `image_otp` branch instead.

## Enrolling

Two ways, and the first is better for anything beyond one machine.

**Supply a secret.** Generate one once, enrol it in your authenticator app, and
pass it on every launch:

```bash
# any base32 string of 16-32 characters; 160 bits is the usual choice
head -c 20 /dev/urandom | base32 | tr -d '='
```

Pass it as `GPU_TOTP_SECRET`. Every machine launched with the same secret
accepts the same codes, which is what you want for a fleet — and restarting a
container does not invalidate your phone.

**Or let the machine generate one.** With no `GPU_TOTP_SECRET` the machine
creates a secret on first start and prints its enrolment URI and a QR code to
the container log, once. Scan it from the provider's log view. Nothing to
provision in advance, but the secret is only as private as that log, and a
restart issues a new one.

This happens wherever `sshd` starts, not only from the image's entrypoint.
RunPod and Vast replace the entrypoint with their own startup script, and an
earlier build that provisioned only from the entrypoint left the gate silently
off on exactly those providers — the binary present, no secret, SSH open on the
key alone. The provisioning now runs from the `sshd` wrapper as well and is
idempotent, so it configures itself on every host either way.

To refuse both, set `GPU_TOTP_ENROLL=false`: SSH stays key-only and the gate is
removed. Useful for a machine you want on the same image without the challenge.

Whichever route you take, check it took effect — a machine that should be
gated and is not looks exactly like a working one:

```bash
ssh -p 2222 root@<host> 'ls -l /etc/gpu-gateway/totp.env; cat /etc/ssh/sshd_config.d/60-gpu-gate.conf'
```

## Running it

```bash
docker run -d --gpus all -p 2222:22 \
  -e PUBLIC_KEY="$(cat ~/.ssh/id_ed25519.pub)" \
  -e GPU_TOTP_SECRET=JBSWY3DPEHPK3PXP... \
  ghcr.io/blackboxai-dev/gpu-verified-image:cuda12.4-totp

ssh -p 2222 root@<host>
```

On a GPU provider, give the image reference and set `PUBLIC_KEY` and
`GPU_TOTP_SECRET` in the launch environment. Both RunPod and Vast read
`PUBLIC_KEY` themselves and install it before `sshd` starts, which is why the
gate works there even though they never run this image's entrypoint.

Where the entrypoint DOES run it installs the keys itself, and accepts
`PUBLIC_KEYS` as well — several keys, one per line, deduplicated — so a person
and a CI runner can share one machine.

## Configuration

| variable | required | meaning |
|---|---|---|
| `PUBLIC_KEY` / `PUBLIC_KEYS` | yes | SSH public keys, one per line. Both are read and deduplicated |
| `GPU_TOTP_SECRET` | no | base32 secret shared with the authenticator app. Absent, one is generated and printed once |
| `GPU_TOTP_ENROLL` | no | `false` refuses to generate a secret; SSH stays key-only. Default `true` |
| `GPU_TOTP_FAILMODE` | no | `open` or `closed`, for when no secret is configured. Default `open` |
| `GPU_TOTP_WINDOW` | no | How many 30s steps either side of now to accept. Default `1`, so about ±30s of clock skew |
| `BLACKBOX_HOST` / `BLACKBOX_GPU` / `BLACKBOX_LOGIN` | no | Shown in the login banner |

## What happens on a login

The gate runs as an `sshd` `ForceCommand`: after the key authenticates and
before any shell or command, on the session's own terminal — which is why it can
prompt at all.

**Only an interactive shell is challenged.** A terminal is what can answer a
prompt, so everything without one passes through untouched:

| what the client did | what happens |
|---|---|
| `ssh host` (a terminal) | challenged, then the shell opens |
| `ssh -t host cmd` (a terminal) | challenged, then `cmd` runs |
| `ssh host cmd` (no terminal) | runs immediately, never prompted |
| `scp`, `sftp`, `rsync` | run immediately, never prompted |

Gating transfers would break every one of them, since an unattended process
cannot type a code. The terminal is tested **before** the command: the other way
round, `ssh -tt host bash -i` passed through — an interactive shell,
unchallenged.

Three wrong codes end the session. A code that has already been accepted is
refused if it is presented again, because a code stays valid for its whole step
and is accepted either side of it, so the same six digits would otherwise work
twice inside about a minute and a half.

### Fail policy

`GPU_TOTP_FAILMODE` applies only when a login **cannot be checked** — no secret
configured, or `oathtool` missing. It never applies to a code that was checked
and rejected.

- `open` (default) lets the login through and logs it as unverified. A machine
  launched without a secret should not be unreachable.
- `closed` refuses it.

Keeping those two cases apart is the point. Collapse them into one and the
default setting waves through every wrong code — a gate that looks like it is
working while verifying nothing.

A broken gate configuration is also never fatal: the provisioner runs `sshd -t`
against what it wrote and removes the gate if `sshd` objects. The machine
degrades to key-only. It never becomes a machine nobody can log into.

It generates the host keys before that check, because `sshd -t` fails without
them and that failure says nothing about the drop-in. Without it the check
deleted the drop-in it had just written, turning the gate off on the providers
that DO run the entrypoint — the mirror image of the bug above, and found the
same way, by starting the image both ways and looking.

## Checking it works

```bash
# interactive login: banner, then a prompt for a code
ssh -p 2222 root@<host>

# a command passes through: no prompt, nothing but its own output
ssh -p 2222 root@<host> 'nvidia-smi -L'

# so does a transfer
scp -P 2222 ./file root@<host>:/tmp/

# the gate is loaded: both lines must appear
ssh -p 2222 root@<host> 'cat /etc/ssh/sshd_config.d/60-gpu-gate.conf'

# the secret is root-only
ssh -p 2222 root@<host> 'ls -l /etc/gpu-gateway/totp.env'

# provenance: commit, build time, source repository
docker inspect ghcr.io/blackboxai-dev/gpu-verified-image:cuda12.4-totp \
  --format '{{json .Config.Labels}}' | python3 -m json.tool
```

## What is in it

`cuda12.4-totp` is a CUDA 12.4 runtime base plus `sshd`, `curl`, CA
certificates, `oathtool` to check the codes and `qrencode` to draw the enrolment
QR. `cuda12.4-ml-totp` adds the toolchain people rent these machines for: the
CUDA compiler and headers, PyTorch, TensorFlow, JupyterLab, NumPy, SciPy,
pandas, scikit-learn, git and a build toolchain.

Both ship **no SSH host keys**. `openssh-server` generates a set when it is
installed, and baking that layer would give every container from the image the
same host identity — with the private half inside an image anyone can pull, so a
client could not tell its own machine from an impostor at the same address. A
fresh set is generated per container, by a wrapper around `sshd` rather than by
the entrypoint, because Vast and RunPod replace the entrypoint and call `sshd`
directly.

Both bases are pinned by digest, not by tag: the upstream tags are republished,
so building the same commit twice against a tag can quietly produce two
different images.

## Building and testing

```bash
docker build -t gpu-verified-image:totp .
docker build -f Dockerfile.ml -t gpu-verified-image:ml-totp .

# the gate, run for real against a known secret: every outcome that decides
# whether somebody gets a shell
sudo apt-get install -y oathtool
./ci/totp-test.sh
```

`ci/totp-test.sh` covers a correct code, a wrong code, a replayed code, a
missing secret under both fail policies, a missing config file, `oathtool`
absent, and both pass-through paths. It stubs only the terminal and the system
logger, which `sshd` provides and CI does not; the gate's own verification is
never mocked.
