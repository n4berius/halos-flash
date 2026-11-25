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
kinds="$repo/files/usr/share/halogen/option-kinds"
ok() { echo "ok: $*"; }
fail() { echo "FAIL: $*" >&2; exit 1; }

# --- the screen's logic, through --batch
d="$work/t"; mkdir -p "$d"
batch() { # <env file> <state> <commands>, then: rc in $rc
  cp "$1" "$d/env"; printf '%s' "$2" > "$d/state"; rc=0
  printf '%s\n' "$3" | python3 -I "$tui" --dir "$d" --template "$tmpl" --allowed "$allowed" --catalog "$catalog" --kinds "$kinds" --batch \
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
> #HALOGEN_KV_POOL_POSITIONS=262144
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
ok "the screen changes only the lines asked for, keeps the rest of the file, and comments out a setting's older lines (keeping their values)"

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
grep -qx '#HALOGEN_NPU_MODELS=future-model,qwen3.5-2b' "$d/env.new" || { cat "$d/env.new" >&2; fail "an empty NPU list wasn't commented out, keeping the old value"; }
ok "reset takes halOS's value, new options go at the end, and the NPU list keeps names it doesn't know"
# The agent guard's spotter isn't in the checklist (HALOGEN_AGENT_GUARD adds it), but a file that
# names it keeps it.
grep -q '^halogen-spotter-0.6b' "$catalog" && fail "the spotter is in the NPU model list"
printf 'HALOGEN_NPU_MODELS=halogen-spotter-0.6b,qwen3.5-2b\n' > "$work/env4"
batch "$work/env4" "" 'npu on decider-0.8b'
grep -qx 'HALOGEN_NPU_MODELS=halogen-spotter-0.6b,qwen3.5-2b,decider-0.8b' "$d/env.new" || { cat "$d/env.new" >&2; fail "a spotter in the file was lost"; }
batch "$work/env4" "" 'npu on halogen-spotter-0.6b'
[ "$rc" != 0 ] || fail "the spotter could be ticked"
# d (the default list) keeps it too, and a file that already had the default list with it
# keeps its order: nothing to save.
dflt=$(sed -n 's/^HALOGEN_NPU_MODELS=//p' "$tmpl")
batch "$work/env4" "" 'npu default'
grep -qx "HALOGEN_NPU_MODELS=$dflt,halogen-spotter-0.6b" "$d/env.new" || { cat "$d/env.new" >&2; fail "d lost the spotter"; }
printf 'HALOGEN_NPU_MODELS=halogen-spotter-0.6b,%s\n' "$dflt" > "$work/env5"
batch "$work/env5" "" 'npu default'
[ "$rc" = 3 ] || { cat "$d/out" >&2; fail "d reordered a file that had the default list (exit $rc)"; }
ok "the agent guard's spotter isn't in the NPU checklist, and a file that names it keeps it, also through d"

# Refusals: nothing is written.
for c in "set HALOGEN_CTX $(printf 'a\033[2Jb')" 'set HALOGEN_NOT_AN_OPTION 1' 'set HALOGEN_CTX  padded ' 'flash half' \
         'flash ../../etc' 'drafter mine other.hgn' 'npu on not-a-model' 'set HALOGEN_NPU_MODELS x'; do
  batch "$work/env" "$state" "$c"
  [ "$rc" = 2 ] || fail "'$c' was taken (exit $rc)"
  if [ -e "$d/env.new" ] || [ -e "$d/choices" ]; then fail "'$c' wrote an answer"; fi
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
batch "$work/env" "$state" 'set HALOGEN_CTX 65536'
python3 -I "$tui" --dir "$d" --template "$repo/variants/no-npu/usr/share/halogen/halogen.env.default" \
  --allowed "$repo/variants/no-npu/usr/share/halogen/options.allowed" --catalog "$catalog" --kinds "$kinds" --batch <<< 'npu on d3-lite' > /dev/null 2>&1 \
  && fail "the no-NPU edition offered NPU models"
ok "only plain names from halogen's folders are offered, and the no-NPU edition has no NPU list"

# --- what each option takes (option-kinds, from Halogen's FLAGS.md)
for e in npu no-npu; do
  rc=0
  python3 -I "$tui" --dir "$d" --template "$repo/variants/$e/usr/share/halogen/halogen.env.default" \
    --allowed "$repo/variants/$e/usr/share/halogen/options.allowed" --catalog "$catalog" --kinds "$kinds" \
    --check-kinds > "$d/out" 2>&1 || rc=$?
  [ "$rc" = 0 ] || { cat "$d/out" >&2; fail "option-kinds doesn't fit the $e edition"; }
done
# No line for an option neither edition allows (one left from an older Halogen).
cut -f1 "$repo"/variants/*/usr/share/halogen/options.allowed | sort -u > "$d/allowed-all"
grep -v '^#' "$kinds" | cut -f1 | sort > "$d/kinds-names"
[ -z "$(comm -23 "$d/kinds-names" "$d/allowed-all")" ] || fail "option-kinds names options no edition allows: $(comm -23 "$d/kinds-names" "$d/allowed-all" | tr '\n' ' ')"
[ -z "$(uniq -d "$d/kinds-names")" ] || fail "option-kinds names an option twice"
# A broken file is found: a missing option, a preset outside its range, a regular expression that
# doesn't compile.
grep -v '^HALOGEN_KV8	' "$kinds" > "$d/k1"
printf 'HALOGEN_KV_SLOTS\tint\t1..64\t1|128\tx\n' >> "$d/k1"
printf 'HALOGEN_PLD\tform\t([0-9]\t0\tx\n' >> "$d/k1"
rc=0
python3 -I "$tui" --dir "$d" --template "$tmpl" --allowed "$allowed" --catalog "$catalog" --kinds "$d/k1" --check-kinds > "$d/out" 2>&1 || rc=$?
if [ "$rc" != 1 ] || ! grep -q 'HALOGEN_KV8: no line' "$d/out" || ! grep -q 'preset 128 is above 64' "$d/out" \
  || ! grep -q '(HALOGEN_PLD)' "$d/out"; then cat "$d/out" >&2; fail "--check-kinds missed a broken option-kinds"; fi
ok "option-kinds has a line for every option of both editions, its presets and halOS's values pass, and a broken file is found"

# Typed values are checked against it: each refused one exits 2, and the accepted ones are saved.
# Each limit is FLAGS.md's (PLD's K up to 7, RETRY_GRACE_S at most 120, no chat markers in the
# thinking message: Halogen refuses to start otherwise), and decimals as render-config reads them.
long="$(printf '%02001d' 0)"
for bad in 'HALOGEN_KV8 2' 'HALOGEN_KV8 true' 'HALOGEN_CTX abc' 'HALOGEN_CTX 0' 'HALOGEN_CTX 2000000' \
  'HALOGEN_KV_SLOTS 1.5' 'HALOGEN_TEMPERATURE 0,7' 'HALOGEN_TEMPERATURE 3' 'HALOGEN_REASONING_EFFORT huge' \
  'HALOGEN_PLD 3' 'HALOGEN_PLD 3,9' 'HALOGEN_RECORD_TEXT prompt,everything' 'HALOGEN_RETRY_GRACE_S 500' \
  'HALOGEN_THINKING_BUDGET_MESSAGE Stop<|im_end|>' 'HALOGEN_THINKING_BUDGET_MESSAGE Done.</think>' \
  'HALOGEN_RECORD_GIB .5' 'HALOGEN_RECORD_GIB 2.' 'HALOGEN_RECORD_DAYS -0' 'HALOGEN_ADMIT_CHUNK -2' \
  "HALOGEN_THINKING_BUDGET_MESSAGE $long" 'HALOGEN_FREQUENCY_PENALTY -3'; do
  batch "$work/env" "$state" "set $bad"
  if [ "$rc" != 2 ] || [ -e "$d/env.new" ]; then fail "set ${bad:0:60} was taken (exit $rc)"; fi
done
batch "$work/env" "$state" 'set HALOGEN_KV8 1
set HALOGEN_CTX 1048576
set HALOGEN_TEMPERATURE 0.6
set HALOGEN_FREQUENCY_PENALTY -0.5
set HALOGEN_REASONING_EFFORT max
set HALOGEN_PLD 3,3
set HALOGEN_RECORD_TEXT prompt,reply
set HALOGEN_MODEL_ID Qwen 3.8 Flash
set HALOGEN_THINKING_BUDGET_MESSAGE Time to answer now.
set HALOGEN_ADMIT_CHUNK -1
set HALOGEN_SSE_KEEPALIVE_S 0
set HALOGEN_FRAG_WARN_STALLS -1
set HALOGEN_DMALLOC_LOG 4096
set HALOGEN_RECORD_GIB 0.5'
[ "$rc" = 0 ] || { cat "$d/out" >&2; fail "accepted values were refused (exit $rc)"; }
for l in HALOGEN_KV8=1 HALOGEN_CTX=1048576 HALOGEN_TEMPERATURE=0.6 HALOGEN_FREQUENCY_PENALTY=-0.5 \
  HALOGEN_REASONING_EFFORT=max HALOGEN_PLD=3,3 HALOGEN_RECORD_TEXT=prompt,reply 'HALOGEN_MODEL_ID=Qwen 3.8 Flash' \
  'HALOGEN_THINKING_BUDGET_MESSAGE=Time to answer now.' HALOGEN_ADMIT_CHUNK=-1 HALOGEN_SSE_KEEPALIVE_S=0 \
  HALOGEN_FRAG_WARN_STALLS=-1 HALOGEN_DMALLOC_LOG=4096 HALOGEN_RECORD_GIB=0.5; do
  grep -qxF "$l" "$d/env.new" || fail "$l wasn't saved"
done
# A value in the file that the screen doesn't accept stays as it is when other settings change.
cp "$work/env" "$work/env-bad"; printf 'HALOGEN_KV8=yes\nHALOGEN_TOP_K=lots\n' >> "$work/env-bad"
batch "$work/env-bad" "$state" 'set HALOGEN_CTX 65536'
[ "$rc" = 0 ] || { cat "$d/out" >&2; fail "a file with refused values couldn't be edited (exit $rc)"; }
grep -qx 'HALOGEN_KV8=yes' "$d/env.new" || fail "a value the screen refuses was changed"
grep -qx 'HALOGEN_TOP_K=lots' "$d/env.new" || fail "a value the screen refuses was changed"
# Without option-kinds (an older image's settings-tui path, say) values are still taken as typed.
cp "$work/env" "$d/env"; printf '' > "$d/state"; rc=0
python3 -I "$tui" --dir "$d" --template "$tmpl" --allowed "$allowed" --catalog "$catalog" --kinds "$d/none" --batch \
  <<< 'set HALOGEN_CTX 512' > "$d/out" 2>&1 || rc=$?
[ "$rc" = 0 ] || fail "without option-kinds a plain value was refused"
ok "values are checked: on/off, choices, number ranges, forms and text length; good ones are saved"

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
    try:
        os.write(fd, k.encode().decode("unicode_escape").encode("latin-1"))
    except OSError:
        break
    drain(0.2)
drain(0.5)
_, st = os.waitpid(pid, 0)
sys.exit(os.waitstatus_to_exitcode(st))
EOF
  cp "$tmpl" "$d/env"; printf '%s' "$state" > "$d/state"; rm -f "$d/env.new" "$d/choices"
  # Menu: Flash checkpoint (Enter), down to "mine", Space, back; down twice to NPU models, Space on
  # the second (decider-4b), back; Common settings, Enter on the first (CTX): its list of presets,
  # down seven to "type a value", type abc (refused, asked again), clear, type 4096; down to
  # KV_SLOTS, Enter, pick the third preset (4); down six to ENABLE_THINKING, its on/off list: 1;
  # back; Review and save, first choice (save and restart).
  rc=0
  python3 "$work/drive.py" '\n|j|j| |q|j|j|\n|j| |q|j|\n|\n|j|j|j|j|j|j|j|\n|abc\n|\x15|4096\n|j|\n|j|j|j|\n|j|j|j|j|j|j|\n|j|j|\n|q|j|j|\n|\n' \
    python3 -I "$tui" --dir "$d" --template "$tmpl" --allowed "$allowed" --catalog "$catalog" --kinds "$kinds" || rc=$?
  [ "$rc" = 0 ] || fail "the screen exited $rc"
  grep -qx 'HALOGEN_CTX=4096' "$d/env.new" || fail "the typed value wasn't saved"
  grep -qx 'HALOGEN_KV_SLOTS=4' "$d/env.new" || fail "the value picked from the presets wasn't saved"
  grep -qx 'HALOGEN_ENABLE_THINKING=1' "$d/env.new" || fail "the value picked from the on/off list wasn't saved"
  if grep -q '^HALOGEN_CTX=abc' "$d/env.new"; then fail "a value that isn't a number was taken"; fi
  grep -qx 'HALOGEN_NPU_MODELS=decider-0.8b,qwen3-embedding-0.6b,qwen3-reranker-0.6b,qwen3guard-gen-0.6b,qwen3.5-2b,decider-4b' "$d/env.new" \
    || { grep NPU_MODELS= "$d/env.new" >&2; fail "the ticked model wasn't added"; }
  printf 'flash mine\nrestart yes\n' | diff "$d/choices" - || fail "the screen's choices"
  # KV_POOL_POSITIONS (Common settings, third line): pick the next preset, then open it again and
  # go up to "default", halOS's 262144: nothing changes, so "Review and save" (twice) has nothing
  # to save, and q quits with exit 3.
  rm -f "$d/env.new" "$d/choices"; rc=0
  python3 "$work/drive.py" 'j|j|j|\n|j|j|\n|j|\n|\n|k|k|\n|q|j|j|\n|\n|q' \
    python3 -I "$tui" --dir "$d" --template "$tmpl" --allowed "$allowed" --catalog "$catalog" --kinds "$kinds" || rc=$?
  if [ "$rc" != 3 ] || [ -e "$d/env.new" ]; then fail "default didn't mean halOS's default (exit $rc)"; fi
  # q on the menu with changes asks; n stays, then q y leaves without saving.
  rm -f "$d/env.new" "$d/choices"; rc=0
  python3 "$work/drive.py" 'j|j|\n| |q|q|n|q|y' \
    python3 -I "$tui" --dir "$d" --template "$tmpl" --allowed "$allowed" --catalog "$catalog" --kinds "$kinds" || rc=$?
  if [ "$rc" != 3 ] || [ -e "$d/env.new" ]; then fail "quitting saved something (exit $rc)"; fi
  ok "the screen works with keys: checkpoint, NPU checklist, a typed value (checked), a preset, an on/off list, default, review and save; quitting asks and saves nothing"
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
  HALOGEN_ENV_TEMPLATE="$tmpl" HALOGEN_ALLOWED_FILE="$allowed" HALOGEN_NPU_CATALOG="$catalog" HALOGEN_OPTION_KINDS="$kinds"
ctl="$repo/files/usr/bin/halogenctl"
cp "$tmpl" "$work/configs/halogen.env"; chmod 0640 "$work/configs/halogen.env"
run() { : > "$work/log"; rc=0; script -qec "$ctl settings $*" /dev/null > "$work/out" 2>&1 || rc=$?; }

printf 'set HALOGEN_CTX 65536\nflash mine\ndrafter mine off\n' > "$work/cmds"
run
[ "$rc" = 0 ] || { cat "$work/out" "$work/log" >&2; fail "settings exit $rc"; }
grep -qx 'HALOGEN_CTX=65536' "$work/configs/halogen.env" || fail "the new halogen.env wasn't saved"
[ "$(stat -c %a "$work/configs/halogen.env")" = 640 ] || fail "halogen.env lost its 0640 mode"
grep -q 'runuser -u halogen -- env -C / sh -c umask 027; t="$(mktemp' "$work/log" || fail "halogen.env wasn't written as halogen"
grep -q 'runuser -u halogen -- env -C / sh -c \[ -f' "$work/log" || fail "halogen.env wasn't read as halogen"
if ! grep -q 'flash-checkpoint drafter mine off' "$work/log" || ! grep -q 'flash-checkpoint use mine' "$work/log"; then
  cat "$work/log" >&2; fail "the checkpoint or draft head wasn't set through flash-checkpoint"
fi
[ "$(grep -c 'restart halogen.service' "$work/log")" = 1 ] || { cat "$work/log" >&2; fail "not exactly one restart"; }
grep -q 'note from render' "$work/out" || fail "render-config's notes weren't shown"
ok "settings saves halogen.env as halogen, sets the checkpoint and draft head through flash-checkpoint, and restarts once"

printf 'set HALOGEN_CTX 1024\nrestart no\n' > "$work/cmds"; run
if grep -q 'restart halogen.service' "$work/log"; then fail "restart no restarted"; fi
grep -q 'next start' "$work/out" || fail "no hint to restart later"
printf 'set HALOGEN_CTX 2048\n' > "$work/cmds"; run --no-restart
if [ "$rc" != 0 ] || ! grep -q -- '--no-restart' "$work/log"; then fail "--no-restart wasn't passed to the screen"; fi
if grep -q 'restart halogen.service' "$work/log"; then fail "--no-restart restarted"; fi
grep -qx 'HALOGEN_CTX=2048' "$work/configs/halogen.env" || fail "--no-restart didn't save"
ok "it restarts only when asked, and --no-restart (setup) only saves"

cp "$work/configs/halogen.env" "$work/keep"
printf 'set HALOGEN_CTX 3000\nflash mine\n' > "$work/cmds"; FAKE_MEANWHILE=1 run
if [ "$rc" != 1 ] || ! grep -q 'changed while you were editing' "$work/out"; then cat "$work/out" >&2; fail "a file changed meanwhile was overwritten"; fi
grep -q 'HALOGEN_CTX=3000' "$work/configs/halogen.env" && fail "the edit replaced another's change"
if grep -q 'flash-checkpoint use\|restart halogen.service' "$work/log"; then cat "$work/log" >&2; fail "a refused save still switched the checkpoint or restarted"; fi
cp "$work/keep" "$work/configs/halogen.env"
: > "$work/cmds"; run
if [ "$rc" != 0 ] || ! grep -q 'Nothing changed' "$work/out"; then fail "no answer wasn't 'Nothing changed'"; fi
if grep -q 'restart halogen.service\|mktemp' "$work/log"; then fail "no answer still wrote or restarted"; fi
printf 'set HALOGEN_CTX 4000\nflash bad\n' > "$work/cmds"; run
[ "$rc" = 2 ] || [ "$rc" = 1 ] || fail "a refused command passed"
rc=0; "$ctl" settings < /dev/null > "$work/out" 2>&1 || rc=$?
if [ "$rc" != 1 ] || ! grep -q 'needs a terminal' "$work/out"; then fail "it ran without a terminal"; fi
# Not a plain file, or too large: refused before the screen opens.
mv "$work/configs/halogen.env" "$work/real.env"; ln -s /dev/zero "$work/configs/halogen.env"
printf 'set HALOGEN_CTX 1\n' > "$work/cmds"; run
if [ "$rc" != 1 ] || grep -q '^tui ' "$work/log"; then cat "$work/out" >&2; fail "a link to /dev/zero was read"; fi
rm "$work/configs/halogen.env"; head -c 1100000 /dev/zero | tr '\0' '#' > "$work/configs/halogen.env"; run
if [ "$rc" != 1 ] || ! grep -q 'larger than 1 MiB' "$work/out"; then cat "$work/out" >&2; fail "a huge halogen.env was taken"; fi
mv -f "$work/real.env" "$work/configs/halogen.env"
ok "a file changed meanwhile isn't overwritten (and nothing else changes then), a link or huge file is refused, no answer changes nothing, and it needs a terminal"

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
