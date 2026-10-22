#!/bin/bash
# Run the gate for real against demo-verifier.py.
#
# `sh -n gpu-gate` only proves the file parses. A gate that parses and then
# denies every login, or prompts for a code the verifier never issues, is
# still a broken gate — and one reached a published image. This exercises the
# three outcomes that matter:
#
#   verifier answers, failmode=open    -> session opens, no prompt
#   verifier answers, failmode=closed  -> session opens, no prompt
#   verifier unreachable, closed       -> session denied
#
# A script rather than inline YAML so it can be run by hand while editing the
# gate, which is when it is most useful.
set -euo pipefail

PORT=${PORT:-8099}
WORK=$(mktemp -d)
cleanup() { kill %1 2>/dev/null || true; wait %1 2>/dev/null || true; rm -rf "$WORK"; }
trap cleanup EXIT

python3 demo-verifier.py "$PORT" >"$WORK/verifier.log" 2>&1 &
for _ in $(seq 1 20); do
  if curl -fsS -m 2 -o /dev/null -X POST "http://127.0.0.1:$PORT/verify" \
       -H 'Authorization: Bearer ci' -H 'Content-Type: application/json' \
       -d '{"fingerprint":"SHA256:probe"}' 2>/dev/null; then break; fi
  sleep 0.5
done

# sshd hands the gate a terminal and the authenticating key's line; neither
# exists in CI, so both are stubbed. Nothing else about the gate is replaced.
mkdir -p "$WORK/bin"
printf '#!/bin/sh\nexit 0\n' > "$WORK/bin/tty"
printf '#!/bin/sh\nexit 0\n' > "$WORK/bin/logger"
chmod +x "$WORK/bin/tty" "$WORK/bin/logger"

ssh-keygen -t ed25519 -N '' -q -f "$WORK/key"
printf 'publickey %s %s\n' \
  "$(cut -d' ' -f1 "$WORK/key.pub")" "$(cut -d' ' -f2 "$WORK/key.pub")" > "$WORK/authinfo"

run_gate() {   # $1 = verify url, $2 = failmode
  printf 'GPU_VERIFY_URL=%s\nGPU_RUN_TOKEN=ci\nGPU_FAILMODE=%s\n' "$1" "$2" > "$WORK/verify.env"
  sed "s|CONF=/etc/gpu-gateway/verify.env|CONF=$WORK/verify.env|" gpu-gate > "$WORK/gate"
  PATH="$WORK/bin:$PATH" SSH_CLIENT='203.0.113.9 5 22' \
    SSH_USER_AUTH="$WORK/authinfo" SHELL=/bin/echo \
    sh "$WORK/gate" </dev/null 2>&1 || true
}

fail() { echo "FAIL: $1"; echo "--- gate output ---"; echo "$2"; exit 1; }

for mode in open closed; do
  out=$(run_gate "http://127.0.0.1:$PORT/verify" "$mode")
  echo "--- verifier answering, failmode=$mode ---"; echo "$out"
  case "$out" in
    *"Logged in."*) ;;
    *) fail "the gate did not open the session under failmode=$mode" "$out";;
  esac
  case "$out" in
    *"Enter the 6-digit code"*)
      fail "the gate prompted for a code the verifier never issues" "$out";;
  esac
done

# Port 1 is closed, so this is a genuinely unreachable verifier.
out=$(run_gate "http://127.0.0.1:1/verify" closed)
echo "--- verifier unreachable, failmode=closed ---"; echo "$out"
case "$out" in
  *"fail closed"*) ;;
  *) fail "an unreachable verifier did not deny under failmode=closed" "$out";;
esac

echo
echo "gate test: all three outcomes correct"
