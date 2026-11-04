#!/usr/bin/env bash
# End-to-end tests for git-veil against local mock repos.
# The "relay" is a directory with its own HOME and git identity; ssh is faked
# by a script that runs the command there. No network, no real ssh.
set -euo pipefail
HERE=$(cd "$(dirname "$0")/.." && pwd)
T=$(mktemp -d "${TMPDIR:-/tmp}/veil-test.XXXXXX"); trap 'rm -rf "$T"' EXIT
RH=$T/relayhome; mkdir -p "$RH"; touch "$RH/.gitconfig"
export PATH="$HERE:$PATH"            # so `git veil` finds ./git-veil
export GIT_CONFIG_GLOBAL=$T/me.gitconfig GIT_CONFIG_NOSYSTEM=1
git config --global user.name "Alice Developer"; git config --global user.email "alice@uni.example"
git config --global init.defaultBranch main; git config --global advice.detachedHead false

cat > "$T/fakessh" <<EOF
#!/usr/bin/env bash
shift; cd "$RH"; export HOME="$RH" GIT_CONFIG_GLOBAL="$RH/.gitconfig"; exec bash -c "\$*"
EOF
chmod +x "$T/fakessh"; export VEIL_SSH=$T/fakessh

n=0; pass(){ n=$((n+1)); echo "  ok $n - $*"; }; fail(){ echo "  NOT OK - $*"; exit 1; }
v(){ echo "  \$ git veil $*"; git veil "$@" 2>&1 | sed 's/^/    /'; return "${PIPESTATUS[0]}"; }
blocked(){ if v "$@"; then fail "expected 'git veil $*' to be refused"; fi; }

# ---- upstream project + its hosted copy + the relay checkout
mkdir "$T/up" && cd "$T/up" && git init -q
mkdir -p src/model out bin
echo "a = 1" > src/app.py; echo "width = 256" > src/model/net.py
head -c 300000 /dev/urandom > out/weights.bin; echo "w: 256" > out/meta.yaml
cat > bin/check.sh <<'EOF'
#!/usr/bin/env bash
test -s out/weights.bin && mkdir -p report && echo ok > report/result.txt
EOF
cat > bin/train.sh <<'EOF'
#!/usr/bin/env bash
mkdir -p runs/$NAME && head -c 999 /dev/urandom > runs/$NAME/weights.bin && cp src/model/net.py runs/$NAME/meta.yaml
echo "trained $NAME with LR=${LR:-?} args=$*"
EOF
chmod +x bin/*.sh; printf 'runs/\nreport/\n' > .gitignore
git add -A; git -c user.name=Org -c user.email=org@corp.example commit -qm "initial"
git clone -q --bare "$T/up" "$T/hosted.git"
git clone -q "$T/hosted.git" "$RH/proj"
GIT_CONFIG_GLOBAL=$RH/.gitconfig git -C "$RH/proj" config user.name "team-17"
GIT_CONFIG_GLOBAL=$RH/.gitconfig git -C "$RH/proj" config user.email "team17@contest.example"
R=$RH/proj

# ---- source repo (yours), private remote = bare repo
git init -q --bare "$T/private.git"
git clone -q "$R" "$T/src" && cd "$T/src"
git remote rename origin relay; git remote add origin "$T/private.git"; git push -q -u origin main
mkdir -p .veil/hooks .github
cat > .veil/config <<EOF
RELAY_HOST=box
RELAY_REPO=proj
NAMESPACE=sync
REQUIRE_TOGETHER=("src/model -> out/weights.bin")
WARN_TOGETHER=("out/weights.bin -> out/meta.yaml")
VERIFY_PATHS=(out src/model)
EOF
printf '# names\nAlice\nuni.example\n' > .veil/denylist
echo 'export PROJ_ENV=loaded' > .veil/hooks/env
cat > .veil/hooks/verify <<'EOF'
set -e; [ "$PROJ_ENV" = loaded ]; bin/check.sh; cp -r report "$VEIL_KEEP_DIR/"
EOF
echo 'NAME=$VEIL_NAME exec bin/train.sh "$@"' > .veil/hooks/run
cat > .veil/hooks/fetch <<'EOF'
printf 'runs/%s/weights.bin\tout/weights.bin\n' "$VEIL_NAME"
printf 'runs/%s/meta.yaml\tout/meta.yaml\n' "$VEIL_NAME"
EOF
echo "* @alice" > .github/CODEOWNERS
git add -A; git commit -qm "Add veil config"; git push -q

echo "# init / status"
v init -y >/dev/null; pass "init"
v status | grep -q "up to date" && pass "status: up to date" || fail "status: up to date"

echo "# export"
git checkout -q -b feat; echo "a = 2" > src/app.py; git commit -qam "Alice: tweak (closes #4)"
git checkout -q main; git merge -q --no-ff feat -m "Merge PR #5 from alice/feat"; git push -q
v export -y -m "Tweak app" >/dev/null
[[ $(git --git-dir="$T/hosted.git" log -1 --format='%an <%ae>|%cn <%ce>|%s') == "team-17 <team17@contest.example>|team-17 <team17@contest.example>|Tweak app" ]] \
  && pass "upstream commit carries only the relay identity" || fail "upstream commit carries only the relay identity"
grep -q "a = 2" "$R/src/app.py" && pass "relay checkout updated" || fail "relay checkout updated"
[[ ! -e $R/.veil && ! -e $R/.github ]] && pass "excluded paths not exported" || fail "excluded paths not exported"
! git --git-dir="$T/hosted.git" log --all --format='%an%ae%cn%ce%B' | grep -qiE 'alice|uni\.example|PR #|closes' && pass "no source metadata upstream" || fail "no source metadata upstream"
! git -C "$R" log --all --format='%an%ae%cn%ce%B' | grep -qiE 'alice|uni\.example' && pass "no source metadata anywhere on relay" || fail "no source metadata anywhere on relay"
[[ -z $(git -C "$R" for-each-ref refs/sync/incoming) ]] && pass "transport ref removed" || fail "transport ref removed"
v export -y | grep -q "nothing to export" && pass "idempotent" || fail "idempotent"

echo "# guards"
echo "# by Alice" >> src/app.py; git commit -qam x; git push -q
blocked export -y; pass "denylist blocks"
git revert --no-edit HEAD >/dev/null; git push -q
echo "width = 512" > src/model/net.py; git commit -qam wider; git push -q
blocked export -y; pass "REQUIRE_TOGETHER blocks"

echo "# stage / run / fetch"
v stage wide --run --env "LR=3e-4" -- --seed 7 | grep -q "trained wide with LR=3e-4 args=--seed 7" && pass "stage --run with env + args" || fail "stage --run with env + args"
[[ $(git -C "$R" log -1 --format=%an refs/sync/runs/wide) == team-17 ]] && pass "staged commit has relay identity" || fail "staged commit has relay identity"
v runs | grep -qE '^ +wide ' && pass "runs lists worktree" || fail "runs lists worktree"
v fetch wide >/dev/null
cmp -s out/weights.bin "$RH/sync-runs/wide/runs/wide/weights.bin" && pass "fetch copies hook-named files" || fail "fetch copies hook-named files"
git add out; git commit -qm "new weights"; git push -q
v export -y -m "Wider model" >/dev/null
[[ -f $(ls -d "$RH"/.sync/verify/*/report/result.txt | head -1) ]] && pass "verify hook ran with env hook, output kept" || fail "verify hook ran with env hook, output kept"
cmp -s "$R/out/weights.bin" out/weights.bin && pass "binary delivered byte-identical" || fail "binary delivered byte-identical"
echo "width = 1024" > src/model/net.py; git commit -qam "even wider"
blocked fetch wide; pass "fetch refuses on provenance mismatch"
v fetch wide --force >/dev/null && pass "fetch --force overrides" || fail "fetch --force overrides"
git reset -q --hard origin/main

echo "# failing verify leaves relay untouched"
before=$(git -C "$R" rev-parse HEAD)
: > out/weights.bin; git commit -qam "broken"; git push -q
blocked export -y; [[ $(git -C "$R" rev-parse HEAD) == "$before" ]] && pass "relay untouched" || fail "relay untouched"
git revert --no-edit HEAD >/dev/null; git push -q

echo "# relay-side changes: block -> pull -> merge -> export"
cd "$T/up"; echo "# upstream fix" >> bin/check.sh; git -c user.name=Org -c user.email=org@corp.example commit -qam "Fix check"
(cd "$R" && GIT_CONFIG_GLOBAL=$RH/.gitconfig git pull -q --no-rebase --no-edit "$T/up" main)
cd "$T/src"; echo "b = 1" >> src/app.py; git commit -qam more; git push -q
blocked export -y; pass "export refuses to erase relay changes"
v pull >/dev/null; git fetch -q origin
git merge -q --no-ff "$(git for-each-ref --format='%(refname:short)' 'refs/remotes/origin/sync/pull-*' | tail -1)" -m "merge sync"; git push -q
grep -q "upstream fix" bin/check.sh && pass "pull brought relay change home" || fail "pull brought relay change home"
v export -y >/dev/null; grep -q "b = 1" "$R/src/app.py" && grep -q "upstream fix" "$R/bin/check.sh" && pass "both changes on relay" || fail "both changes on relay"

echo "# dirty relay checkout is protected"
echo "hand edit" >> "$R/src/app.py"; echo "c = 1" >> src/app.py; git commit -qam c; git push -q
blocked export -y; pass "refused"
git -C "$R" checkout -q -- src/app.py; v export -y >/dev/null && pass "succeeds once clean" || fail "succeeds once clean"

echo "# drop"
echo y | git veil drop wide 2>/dev/null; [[ ! -e $RH/sync-runs/wide && -z $(git -C "$R" for-each-ref refs/sync/runs/wide) ]] && pass "drop removes worktree and ref" || fail "drop"

echo "# tags map source -> relay commits"
t=$(git for-each-ref --sort=-refname --count=1 --format='%(refname:short)' refs/tags/sync)
[[ $(git for-each-ref --format='%(contents)' "refs/tags/$t" | sed -n 's/^relay-commit: //p') == $(git -C "$R" rev-parse HEAD) ]] && pass "latest tag $t -> relay HEAD" || fail "latest tag $t -> relay HEAD"

echo "all $n tests passed"
