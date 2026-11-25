#!/bin/bash
# sudo halogenctl settings: the settings screen (settings-tui) and how halogenctl applies its
# answer. The screen edits a private copy and keeps the file's own lines; halogenctl writes it
# back as halogen, switches the checkpoint and draft heads through flash-checkpoint, and restarts
# Halogen once, only when asked. Fake runuser, systemctl, systemd-run and the editor.
# shellcheck disable=SC2016 # The fake commands expand their variables when they run.
set -euo pipefail
repo="$(cd "$(dirname "$0")/.." && pwd)"
work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT
tui="$repo/files/usr/libexec/halogen/settings-tui"
tmpl="$repo/variants/npu/usr/share/halogen/halogen.env.default"
allowed="$repo/variants/npu/usr/share/halogen/options.allowed"
catalog="$repo/files/usr/share/halogen/npu-models.list"
ok() { echo "ok: $*"; }
fail() { echo "FAIL: $*" >&2; exit 1; }

# --- the screen's logic, through --batch
d="$work/t"; mkdir -p "$d"
batch() { # <env file> <state> <commands>, then: rc in $rc
  cp "$1" "$d/env"; printf '%s' "$2" > "$d/state"; rc=0
  printf '%s\n' "$3" | python3 -I "$tui" --dir "$d" --template "$tmpl" --allowed "$allowed" --catalog "$catalog" --batch \
    > "$d/out" 2>&1 || rc=$?
}
cp "$tmpl" "$work/env"
printf 'HALOGEN_CTX=1000\nHALOGEN_CTX="2000"\nSOMETHING_ELSE=kept\n' >> "$work/env"
state=$'running yes\nflash-chosen official\nflash mine pass mine-drafter.hgn\nflash half no\nnpu-downloaded qwen3.5-2b\nown LFM/My-LFM\n'
batch "$work/env" "$state" 'set HALOGEN_CTX 131072
set HALOGEN_TEMPERATURE 0.7
npu on d3-lite
npu off qwen3.5-2b
npu on /models/LFM/My-LFM
flash mine
drafter mine mine-drafter.hgn
default HALOGEN_KV_POOL_POSITIONS'
[ "$rc" = 0 ] || { cat "$d/out" >&2; fail "batch edit exit $rc"; }
diff <(diff "$work/env" "$d/env.new" | grep '^[<>]') - <<'EOF' || fail "the edit changed more or less than asked"
< #HALOGEN_TEMPERATURE=
> HALOGEN_TEMPERATURE=0.7
< HALOGEN_KV_POOL_POSITIONS=262144
> #HALOGEN_KV_POOL_POSITIONS=
< HALOGEN_NPU_MODELS=decider-0.8b,qwen3-embedding-0.6b,qwen3-reranker-0.6b,qwen3guard-gen-0.6b,qwen3.5-2b
> HALOGEN_NPU_MODELS=decider-0.8b,qwen3-embedding-0.6b,qwen3-reranker-0.6b,qwen3guard-gen-0.6b,d3-lite,/models/LFM/My-LFM
< HALOGEN_CTX=1000
< HALOGEN_CTX="2000"
> #HALOGEN_CTX=1000
> HALOGEN_CTX=131072
EOF
diff "$d/choices" - <<'EOF' || fail "wrong choices"
flash mine
drafter mine mine-drafter.hgn
restart yes
EOF
ok "the screen changes only the lines asked for, keeps the rest of the file, and comments out a setting's older lines"

# reset goes back to halOS's own value; an option the file never mentioned is added at the end.
printf 'HALOGEN_KV_POOL_POSITIONS=1\n' > "$work/env2"
batch "$work/env2" "" 'reset HALOGEN_KV_POOL_POSITIONS
set HALOGEN_KV8 1
restart no'
[ "$rc" = 0 ] || fail "reset: exit $rc"
diff "$d/env.new" - <<'EOF' || fail "reset or append went wrong"
HALOGEN_KV_POOL_POSITIONS=262144

# Set with sudo halogenctl settings
HALOGEN_KV8=1
EOF
grep -qx 'restart no' "$d/choices" || fail "restart no wasn't kept"
# A name the file has that halOS's list doesn't know stays, in its place.
printf 'HALOGEN_NPU_MODELS=future-model,qwen3.5-2b\n' > "$work/env3"
batch "$work/env3" "" 'npu on decider-0.8b'
grep -qx 'HALOGEN_NPU_MODELS=future-model,qwen3.5-2b,decider-0.8b' "$d/env.new" || { cat "$d/env.new" >&2; fail "an unknown NPU name was lost"; }
batch "$work/env3" "" 'npu off future-model
npu off qwen3.5-2b'
grep -qx '#HALOGEN_NPU_MODELS=' "$d/env.new" || { cat "$d/env.new" >&2; fail "an empty NPU list wasn't commented out"; }
ok "reset takes halOS's value, new options go at the end, and the NPU list keeps names it doesn't know"

# Refusals: nothing is written.
for c in "set HALOGEN_CTX $(printf 'a\033[2Jb')" 'set HALOGEN_NOT_AN_OPTION 1' 'set HALOGEN_CTX  padded ' 'flash half' \
         'flash ../../etc' 'drafter mine other.hgn' 'npu on not-a-model' 'set HALOGEN_NPU_MODELS x'; do
  batch "$work/env" "$state" "$c"
  [ "$rc" = 2 ] || fail "'$c' was taken (exit $rc)"
  [ ! -e "$d/env.new" ] && [ ! -e "$d/choices" ] || fail "'$c' wrote an answer"
done
batch "$work/env" "$state" ''
[ "$rc" = 3 ] || fail "no change didn't exit 3"
ok "control characters, unknown options, unusable checkpoints and unknown draft heads are refused; no change writes nothing"

# Names from halogen's folders are taken only when plain.
evil=$'flash $(touch '"$work"$'/pwned) pass\nflash bad\033]0;x pass\nnpu-downloaded a;b\nown LFM/../../configs\nown custom/ok-one\ndrafter x=$(id)\n'
batch "$work/env" "$evil" 'npu on /models/custom/ok-one'
[ "$rc" = 0 ] || { cat "$d/out" >&2; fail "plain names: exit $rc"; }
batch "$work/env" "$evil" 'npu on /models/LFM/../../configs'
[ "$rc" = 2 ] || fail "a folder name with .. was offered"
batch "$work/env" "$evil" 'flash bad'
[ "$rc" = 2 ] || fail "a checkpoint name with an escape was offered"
[ ! -e "$work/pwned" ] || fail "a name ran a command"
# The no-NPU edition has no NPU list and never touches it.
batch "$work/env" "$state" 'set HALOGEN_CTX 5'
python3 -I "$tui" --dir "$d" --template "$repo/variants/no-npu/usr/share/halogen/halogen.env.default" \
  --allowed "$repo/variants/no-npu/usr/share/halogen/options.allowed" --catalog "$catalog" --batch <<< 'npu on d3-lite' > /dev/null 2>&1 \
  && fail "the no-NPU edition offered NPU models"
ok "only plain names from halogen's folders are offered, and the no-NPU edition has no NPU list"

# --- the screen itself, in a pseudo-terminal: keys as a person types them.
if python3 -c 'import curses; curses.setupterm("xterm")' 2> /dev/null; then
  cat > "$work/drive.py" <<'EOF'
import fcntl, os, pty, select, struct, sys, termios, time
keys = sys.argv[1].split("|")
pid, fd = pty.fork()
if pid == 0:
    os.environ["TERM"] = "xterm"
    os.execvp(sys.argv[2], sys.argv[2:])
fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", 40, 110, 0, 0))
def drain(t):
    end = time.time() + t
    while time.time() < end:
        if select.select([fd], [], [], 0.05)[0]:
            try:
                os.read(fd, 65536)
            except OSError:
                return
drain(1.0)
for k in keys:
    os.write(fd, k.encode().decode("unicode_escape").encode("latin-1"))
    drain(0.2)
drain(0.5)
_, st = os.waitpid(pid, 0)
sys.exit(os.waitstatus_to_exitcode(st))
EOF
  cp "$tmpl" "$d/env"; printf '%s' "$state" > "$d/state"; rm -f "$d/env.new" "$d/choices"
  # Menu: Flash checkpoint (Enter), down to "mine", Space, back; down twice to NPU models, Space on
  # the second (decider-4b), back; Common settings, Enter on the first (CTX), type 4096, back;
  # Review and save, first choice (save and restart).
  rc=0
  python3 "$work/drive.py" '\n|j|j| |q|j|j|\n|j| |q|j|\n|\n|4096\n|q|j|j|\n|\n' \
    python3 -I "$tui" --dir "$d" --template "$tmpl" --allowed "$allowed" --catalog "$catalog" || rc=$?
  [ "$rc" = 0 ] || fail "the screen exited $rc"
  grep -qx 'HALOGEN_CTX=4096' "$d/env.new" || fail "the typed value wasn't saved"
  grep -qx 'HALOGEN_NPU_MODELS=decider-0.8b,qwen3-embedding-0.6b,qwen3-reranker-0.6b,qwen3guard-gen-0.6b,qwen3.5-2b,decider-4b' "$d/env.new" \
    || { grep NPU_MODELS= "$d/env.new" >&2; fail "the ticked model wasn't added"; }
  printf 'flash mine\nrestart yes\n' | diff "$d/choices" - || fail "the screen's choices"
  # q on the menu with changes asks; n stays, then q y leaves without saving.
  rm -f "$d/env.new" "$d/choices"; rc=0
  python3 "$work/drive.py" 'j|j|\n| |q|q|n|q|y' \
    python3 -I "$tui" --dir "$d" --template "$tmpl" --allowed "$allowed" --catalog "$catalog" || rc=$?
  [ "$rc" = 3 ] && [ ! -e "$d/env.new" ] || fail "quitting saved something (exit $rc)"
  ok "the screen works with keys: checkpoint, NPU checklist, a typed value, review and save; quitting asks and saves nothing"
else
  echo "skip: no xterm terminfo here, so the screen itself isn't driven"
fi

# --- halogenctl settings: applying the answer
mkdir -p "$work/bin" "$work/configs" "$work/models/flash/mine" "$work/locks" "$work/hstate"
export FAKE="$work"
f() { printf '#!/bin/bash\n%s\n' "$2" > "$work/bin/$1"; chmod +x "$work/bin/$1"; }
f runuser 'echo "runuser $*" >> "$FAKE/log"; [ "$1 $2 $3" = "-u halogen --" ] || exit 9; shift 3; exec "$@"'
f systemctl 'echo "systemctl $*" >> "$FAKE/log"; case "$*" in *"is-active --quiet halogen.service"*) [ -z "${FAKE_INACTIVE:-}" ] ;; esac'
f systemd-run 'echo "systemd-run $*" >> "$FAKE/log"; case "$*" in *"flash-checkpoint use bad"*) exit 1 ;; *render-config*) echo "halogen-config: note from render" ;; esac'
f nano 'echo "nano $*" >> "$FAKE/log"; echo "HALOGEN_KV_SLOTS=2" >> "$1"'
# The screen, answered from a file of batch commands; FAKE_MEANWHILE stands for another admin.
f tui 'echo "tui $*" >> "$FAKE/log"; [ -z "${FAKE_MEANWHILE:-}" ] || echo "# changed" >> "$FAKE/configs/halogen.env"
  [ -s "$FAKE/cmds" ] || exit 3; exec python3 -I "$FAKE_TUI" "$@" --batch < "$FAKE/cmds"'
printf 'verified=pass\ndrafter=mine-drafter.hgn\nrepo=x\n' > "$work/models/flash/mine/halos.info"
export PATH="$work/bin:$PATH" HALOGEN_CONFIGS_DIR="$work/configs" HALOGEN_MODELS_DIR="$work/models" FAKE_TUI="$tui" \
  HALOS_LOCK_DIR="$work/locks" HALOGEN_STATE_DIR="$work/hstate" HALOGEN_SETTINGS_TUI="$work/bin/tui" \
  HALOGEN_ENV_TEMPLATE="$tmpl" HALOGEN_ALLOWED_FILE="$allowed" HALOGEN_NPU_CATALOG="$catalog"
ctl="$repo/files/usr/bin/halogenctl"
cp "$tmpl" "$work/configs/halogen.env"; chmod 0640 "$work/configs/halogen.env"
run() { : > "$work/log"; rc=0; script -qec "$ctl settings $*" /dev/null > "$work/out" 2>&1 || rc=$?; }

printf 'set HALOGEN_CTX 65536\nflash mine\ndrafter mine off\n' > "$work/cmds"
run
[ "$rc" = 0 ] || { cat "$work/out" "$work/log" >&2; fail "settings exit $rc"; }
grep -qx 'HALOGEN_CTX=65536' "$work/configs/halogen.env" || fail "the new halogen.env wasn't saved"
[ "$(stat -c %a "$work/configs/halogen.env")" = 640 ] || fail "halogen.env lost its 0640 mode"
grep -q 'runuser -u halogen -- env -C / sh -c' "$work/log" || fail "halogen.env wasn't written as halogen"
grep -q 'runuser -u halogen -- env -C / cat' "$work/log" || fail "halogen.env wasn't read as halogen"
grep -q 'flash-checkpoint drafter mine off' "$work/log" && grep -q 'flash-checkpoint use mine' "$work/log" \
  || { cat "$work/log" >&2; fail "the checkpoint or draft head wasn't set through flash-checkpoint"; }
[ "$(grep -c 'restart halogen.service' "$work/log")" = 1 ] || { cat "$work/log" >&2; fail "not exactly one restart"; }
grep -q 'note from render' "$work/out" || fail "render-config's notes weren't shown"
ok "settings saves halogen.env as halogen, sets the checkpoint and draft head through flash-checkpoint, and restarts once"

printf 'set HALOGEN_CTX 1024\nrestart no\n' > "$work/cmds"; run
if grep -q 'restart halogen.service' "$work/log"; then fail "restart no restarted"; fi
grep -q 'next start' "$work/out" || fail "no hint to restart later"
printf 'set HALOGEN_CTX 2048\n' > "$work/cmds"; run --no-restart
[ "$rc" = 0 ] && grep -q -- '--no-restart' "$work/log" || fail "--no-restart wasn't passed to the screen"
if grep -q 'restart halogen.service' "$work/log"; then fail "--no-restart restarted"; fi
grep -qx 'HALOGEN_CTX=2048' "$work/configs/halogen.env" || fail "--no-restart didn't save"
ok "it restarts only when asked, and --no-restart (setup) only saves"

cp "$work/configs/halogen.env" "$work/keep"
printf 'set HALOGEN_CTX 3000\n' > "$work/cmds"; FAKE_MEANWHILE=1 run
[ "$rc" = 1 ] && grep -q 'changed while you were editing' "$work/out" || { cat "$work/out" >&2; fail "a file changed meanwhile was overwritten"; }
grep -q 'HALOGEN_CTX=3000' "$work/configs/halogen.env" && fail "the edit replaced another's change"
cp "$work/keep" "$work/configs/halogen.env"
: > "$work/cmds"; run
[ "$rc" = 0 ] && grep -q 'Nothing changed' "$work/out" || fail "no answer wasn't 'Nothing changed'"
if grep -q 'restart halogen.service\|sh -c' "$work/log"; then fail "no answer still wrote or restarted"; fi
printf 'set HALOGEN_CTX 4000\nflash bad\n' > "$work/cmds"; run
[ "$rc" = 2 ] || [ "$rc" = 1 ] || fail "a refused command passed"
rc=0; "$ctl" settings < /dev/null > "$work/out" 2>&1 || rc=$?
[ "$rc" = 1 ] && grep -q 'needs a terminal' "$work/out" || fail "it ran without a terminal"
ok "a file changed meanwhile isn't overwritten, no answer changes nothing, and it needs a terminal"

# --editor: root edits a private copy; the result goes back as halogen.
run --editor
if ! grep -qE "^nano /tmp/.*/env$" "$work/log"; then cat "$work/log" >&2; fail "the editor didn't open a private copy"; fi
if grep -q "nano $work/configs" "$work/log"; then fail "the editor opened halogen's file directly"; fi
grep -qx 'HALOGEN_KV_SLOTS=2' "$work/configs/halogen.env" || fail "the editor's change wasn't saved"
ok "--editor edits a private copy and writes it back as halogen"

# The checklist knows every NPU model the template turns on.
for id in $(sed -n 's/^HALOGEN_NPU_MODELS=//p' "$tmpl" | tr ',' ' '); do
  grep -q "^$id	" "$catalog" || fail "$id (in the template's NPU list) is missing from npu-models.list"
done
ok "npu-models.list has every model the template turns on"
