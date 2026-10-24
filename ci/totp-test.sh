#!/bin/bash
# Run the authenticator gate for real.
#
# `sh -n gpu-gate` only proves the file parses. A gate that parses and then
# refuses every correct code, or accepts any six digits, is still a broken gate
# — and a gate that parsed reached a published image once. This exercises every
# outcome that decides whether somebody gets a shell:
#
#   correct code                  -> session opens
#   wrong code, three times       -> denied
#   the same correct code twice   -> second one refused as a replay
#   no secret, failmode=open      -> opens, unverified
#   no secret, failmode=closed    -> denied
#   no config file at all         -> opens, unverified
#   oathtool missing, closed      -> denied
#   no tty + command              -> command runs, never prompted
#   no tty + no command           -> handed to sftp-server
#
# Needs oathtool, which is also what the gate uses. A script rather than inline
# YAML so it can be run by hand while editing the gate, which is when it is
# most useful.
set -euo pipefail

command -v oathtool >/dev/null 2>&1 || { echo "SKIP: oathtool not installed"; exit 0; }

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

SECRET=JBSWY3DPEHPK3PXPJBSWY3DPEHPK3PXP      # RFC-style base32, 32 chars
PASS=0; FAILED=0

# sshd hands the gate a terminal; CI has none, so tty is stubbed. logger is
# stubbed because syslog is not running. Nothing else about the gate is
# replaced, and the gate's own verification is never mocked.
mkdir -p "$WORK/bin"
printf '#!/bin/sh\nexit 0\n'  > "$WORK/bin/tty"       # tty -s succeeds: we have a terminal
printf '#!/bin/sh\nexit 0\n'  > "$WORK/bin/logger"
chmod +x "$WORK/bin/tty" "$WORK/bin/logger"

mkdir -p "$WORK/notty"
printf '#!/bin/sh\nexit 1\n'  > "$WORK/notty/tty"     # tty -s fails: no terminal
printf '#!/bin/sh\nexit 0\n'  > "$WORK/notty/logger"
chmod +x "$WORK/notty/tty" "$WORK/notty/logger"

# The gate under test, with its two absolute paths redirected into the sandbox.
# Nothing else is rewritten.
build_gate() {
  sed -e "s|CONF=/etc/gpu-gateway/totp.env|CONF=$WORK/totp.env|" \
      -e "s|STATE=/run/gpu-gate-last|STATE=$WORK/last|" gpu-gate > "$WORK/gate"
}
build_gate

conf() {   # $1 = secret ("" for none), $2 = failmode
  if [ -z "$1" ]; then
    printf 'GPU_TOTP_FAILMODE=%s\n' "$2" > "$WORK/totp.env"
  else
    printf 'GPU_TOTP_SECRET=%s\nGPU_TOTP_FAILMODE=%s\n' "$1" "$2" > "$WORK/totp.env"
  fi
}

run() {    # stdin = codes to type; $1 = bin dir; rest = extra env
  local bindir="$1"; shift
  env -i PATH="$bindir:/usr/local/bin:/usr/bin:/bin" \
      SSH_CLIENT='203.0.113.9 5 22' SHELL=/bin/echo HOME="$WORK" "$@" \
      sh "$WORK/gate" 2>&1 || true
}

check() {  # $1 = label, $2 = output, $3 = must contain, $4 = must NOT contain (optional)
  local label="$1" out="$2" want="$3" deny="${4:-}"
  if [[ "$out" != *"$want"* ]]; then
    echo "FAIL  $label"; echo "      wanted: $want"; echo "--- output ---"; echo "$out"; echo "---"
    FAILED=$((FAILED+1)); return
  fi
  if [ -n "$deny" ] && [[ "$out" == *"$deny"* ]]; then
    echo "FAIL  $label"; echo "      must not contain: $deny"; echo "--- output ---"; echo "$out"; echo "---"
    FAILED=$((FAILED+1)); return
  fi
  echo "ok    $label"; PASS=$((PASS+1))
}

code_now() { oathtool --totp -b "$SECRET"; }

echo "== authenticator gate =="

# 1. the correct code opens a session
conf "$SECRET" open
rm -f "$WORK/last"
out=$(code_now | run "$WORK/bin")
check "correct code opens the session" "$out" "Verified."

# 2. a wrong code is refused, three attempts then out
conf "$SECRET" open
rm -f "$WORK/last"
out=$(printf '000000\n000000\n000000\n' | run "$WORK/bin")
check "wrong code is refused"            "$out" "Incorrect or expired code."
check "wrong code does not open a shell" "$out" "Two-factor verification failed." "Verified."

# 3. replay: the same correct code a second time is refused
conf "$SECRET" open
rm -f "$WORK/last"
C=$(code_now)
out=$(printf '%s\n' "$C" | run "$WORK/bin")
check "first use of a code accepted" "$out" "Verified."
out=$(printf '%s\n%s\n%s\n' "$C" "$C" "$C" | run "$WORK/bin")
check "replayed code refused" "$out" "That code has already been used." "Verified."

# 4. no secret, failmode=open -> allowed but unverified
conf "" open
rm -f "$WORK/last"
out=$(run "$WORK/bin" </dev/null)
check "no secret + open allows" "$out" "" "Enter the 6-digit code"

# 5. no secret, failmode=closed -> denied
conf "" closed
out=$(run "$WORK/bin" </dev/null)
check "no secret + closed denies" "$out" "fail closed" "Verified."

# 6. no config file at all -> allowed, unverified
rm -f "$WORK/totp.env" "$WORK/last"
out=$(run "$WORK/bin" </dev/null)
check "no config allows" "$out" "" "Enter the 6-digit code"

# 7. oathtool unavailable, failmode=closed -> denied (never silently allowed).
# A PATH holding everything the gate needs EXCEPT oathtool. The interpreter is
# named absolutely, since PATH no longer has to contain a shell for the gate to
# be run the way sshd runs it.
conf "$SECRET" closed
mkdir -p "$WORK/noath"
cp "$WORK/bin/tty" "$WORK/bin/logger" "$WORK/noath/"
for t in cut tr date chmod getent id grep awk; do
  tp=$(command -v "$t" 2>/dev/null) && ln -sf "$tp" "$WORK/noath/$t"
done
[ -x "$WORK/noath/oathtool" ] && { echo "FAIL  harness leaked oathtool"; exit 1; }
out=$(env -i PATH="$WORK/noath" SSH_CLIENT='203.0.113.9 5 22' SHELL=/bin/echo \
        /bin/sh "$WORK/gate" </dev/null 2>&1 || true)
check "oathtool missing + closed denies" "$out" "fail closed" "Verified."

# 8. no terminal + a command -> runs it, never prompts
conf "$SECRET" closed
out=$(run "$WORK/notty" SSH_ORIGINAL_COMMAND='echo transferred')
check "no tty + command passes through" "$out" "transferred" "Enter the 6-digit code"

# 9. no terminal + no command -> handed to sftp-server, never prompted
out=$(run "$WORK/notty" </dev/null)
check "no tty + no command -> sftp" "$out" "" "Enter the 6-digit code"


# ── the provisioner, which decides whether the gate exists at all ───────────
#
# These run it directly rather than through a container, so they hold for every
# host. The container-level proof that it works with the entrypoint REPLACED is
# in the image build; what is checked here is the logic that made it possible.
echo
echo "== provisioner =="

prov_env() {   # run the provisioner against a sandbox, $@ = env assignments
  rm -rf "$WORK/p"; mkdir -p "$WORK/p/etc/gpu-gateway" "$WORK/p/etc/ssh/sshd_config.d"
  sed -e "s|CONF=/etc/gpu-gateway/totp.env|CONF=$WORK/p/etc/gpu-gateway/totp.env|" \
      -e "s|DROPIN=/etc/ssh/sshd_config.d/60-gpu-gate.conf|DROPIN=$WORK/p/etc/ssh/sshd_config.d/60-gpu-gate.conf|" \
      -e "s|mkdir -p /etc/gpu-gateway /etc/ssh/sshd_config.d|mkdir -p $WORK/p/etc/gpu-gateway $WORK/p/etc/ssh/sshd_config.d|" \
      gpu-provision-totp > "$WORK/prov"
  env -i PATH="$PATH" "$@" sh "$WORK/prov" 2>&1 || true
}

out=$(prov_env GPU_TOTP_SECRET=JBSWY3DPEHPK3PXP)
check "a supplied secret is written" "$(cat "$WORK/p/etc/gpu-gateway/totp.env" 2>/dev/null)" "GPU_TOTP_SECRET=JBSWY3DPEHPK3PXP"
check "a supplied secret turns the gate on" "$(cat "$WORK/p/etc/ssh/sshd_config.d/60-gpu-gate.conf" 2>/dev/null)" "ForceCommand"
check "a supplied secret prints no enrolment" "$out" "" "ENROL YOUR AUTHENTICATOR"

out=$(prov_env)
check "no secret generates one"        "$(cat "$WORK/p/etc/gpu-gateway/totp.env" 2>/dev/null)" "GPU_TOTP_SECRET="
check "a generated secret is enrollable" "$out" "otpauth://totp/"
check "a generated secret turns the gate on" "$(cat "$WORK/p/etc/ssh/sshd_config.d/60-gpu-gate.conf" 2>/dev/null)" "ForceCommand"

out=$(prov_env GPU_TOTP_ENROLL=false)
check "enrol=false leaves no gate" "$([ -f "$WORK/p/etc/ssh/sshd_config.d/60-gpu-gate.conf" ] && echo gated || echo keyonly)" "keyonly"

# Idempotence is what lets the entrypoint and the sshd wrapper both call it.
prov_env GPU_TOTP_SECRET=FIRSTSECRETAAAAAAAAAAAAAAAAAAAAA >/dev/null
first=$(cat "$WORK/p/etc/gpu-gateway/totp.env")
env -i PATH="$PATH" GPU_TOTP_SECRET=SECONDSECRETBBBBBBBBBBBBBBBBBBBB sh "$WORK/prov" >/dev/null 2>&1 || true
check "a second run leaves the first secret alone" "$(cat "$WORK/p/etc/gpu-gateway/totp.env")" "$first"

# The host-key ordering bug: the validation must not delete its own drop-in.
check "the provisioner generates host keys before validating" \
  "$(cat gpu-provision-totp)" "ssh-keygen -A"

# Both callers must invoke it, or one class of host silently loses the gate.
check "the sshd wrapper provisions too" "$(cat sshd-wrapper)" "gpu-provision-totp"
check "the entrypoint provisions too"   "$(cat entrypoint.sh)" "gpu-provision-totp"

echo
echo "passed $PASS, failed $FAILED"
[ "$FAILED" -eq 0 ] || exit 1
echo "authenticator gate: every outcome correct"
