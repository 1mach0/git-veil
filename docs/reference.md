# git-veil reference

**Work in your own repo with your own history. Publish clean, anonymous snapshots
through a relay host whose git identity you don't control.**

Sometimes the only way to push to a repository is from a machine someone else set
up: a provisioned server with one shared account, a pre-configured `user.name` /
`user.email`, and push credentials that never leave it. You still want normal
collaboration on your side: branches, pull requests, reviews and issues, with
your names on them. But none of that should show up downstream.

`git veil` connects the two:

```
your repo (private)  ──git veil export──▶  relay repo  ──git push──▶  upstream
        ▲                                       │
        └────── git veil pull (new branch) ◀────┘   changes made on the relay
```

- **Only file snapshots cross over.** Each relay commit is created *on the relay*
  with `git commit-tree`, so it carries the relay's own identity and clock. Your
  authors, commit messages, branch names, PR numbers and tags never reach the relay.
- **Nothing on the relay gets clobbered.** Export refuses to overwrite changes that
  exist only on the relay (someone else's commit, an upstream merge). `pull` turns
  those changes into a branch you can review and merge.
- **Leaks are checked before anything leaves.** Every changed file (binaries
  included), file name and commit message is scanned against your denylist.
- **The relay can be your compute box.** `stage` puts any branch into its own
  worktree on the relay and runs your job there. `fetch` brings results back,
  after checking they were produced by the code you're about to commit them with.

It's one bash script. On your machine it needs bash ≥ 4.4 and git. On the relay it
needs git, bash and `base64`, and no root access.

## When to use it, and when not to

Good fits:

- A competition or course hands each team a server account that is the only
  allowed way to submit, and submissions should stay anonymous within the team.
- A contractor or consortium pushes to a client repo through a client-managed
  host and service identity, but does day-to-day work in its own repo.
- A shared GPU box with one login, where you want experiments tied to exact
  commits without editing code on the box.

Don't use it to hide authorship where the rules require it. If a project needs
per-person attribution (a DCO sign-off, a CLA, a policy that commits name their
author), git-veil works against that.

## How it works

1. `export` reads your reviewed branch (`origin/main` by default) into a temporary
   index. It swaps in the relay's own copy of excluded paths (`.veil/`, `.github/`
   by default) and writes a tree.
2. Safety checks run against that tree: relay drift, the denylist, file-size
   limits and your `REQUIRE_TOGETHER` rules.
3. The tree is pushed to the relay inside a throwaway commit at
   `refs/<namespace>/incoming`. It has a neutral author, a fixed date, and is
   deleted straight away.
4. Over SSH, the relay checks that its checkout is clean and on the expected
   commit. It then runs `git commit-tree <tree> -p HEAD` with its own
   configuration. Optionally it runs your `verify` hook in a clean worktree of
   that commit. Finally it fast-forwards and pushes upstream.
5. Back home, your source commit is tagged `<namespace>/NNNN-<utc>`, with the
   relay commit recorded in the tag message. These tags are how the next export
   knows what the relay already has.

| Thing | Reaches the relay / upstream? |
|---|---|
| File contents of the exported branch (minus `EXCLUDE`) | yes |
| Commit message | only the one you pass with `-m` |
| Author/committer identity and dates | no: the relay's own identity and clock are used |
| Your history, branches, tags, PRs, issues | no |
| `.veil/` (config, denylist, hooks) | no; hooks are streamed over SSH when they run |

## Install

```bash
git clone https://github.com/<you>/git-veil && cd git-veil
make install            # copies git-veil to ~/.local/bin; then `git veil --help` works
```

On macOS, run `brew install bash` first, because the system bash is 3.2.

## Quick start

```bash
# 1. Start your repo from the relay's repo so the two share history
git clone relay-box:path/to/repo myproj && cd myproj
git remote rename origin relay
git remote add origin git@github.com:you/myproj-private.git
git push -u origin main

# 2. Configure
mkdir -p .veil
cat > .veil/config <<'EOF'
RELAY_HOST=relay-box          # ssh alias from ~/.ssh/config
RELAY_REPO=path/to/repo       # on the relay, relative to ~
RELAY_PUSH_REMOTE=origin      # remote on the relay to push to
NAMESPACE=sync                # choose something bland (see Caveats)
EOF
printf 'your-name\nyour-handle\nyour-company.com\n' > .veil/denylist
git add .veil && git commit -m "Add git-veil config" && git push

# 3. Record the starting point, then ship whenever main moves
git veil init
git veil status
git veil export -m "Short, neutral message"
```

## Commands

| Command | What it does |
|---|---|
| `init [-y]` | Records that your source branch and the relay's HEAD match right now. Run once. |
| `status` | Shows what export would send, and any relay-side changes you don't have yet. |
| `export [-m MSG] [-y] [--verify\|--no-verify] [--no-push] [--allow-unpaired] [--ref REF]` | Makes one relay commit from the snapshot, then fast-forwards and pushes. |
| `pull` | Puts relay-only changes on a `<ns>/pull-<utc>` branch in your repo. Merge it, then export. |
| `stage NAME [--ref REF] [--run] [--env 'K=V …'] [-- ARGS]` | Snapshots a ref into `~/<ns>-runs/NAME` on the relay (its own worktree and commit). Optionally runs the `run` hook there. |
| `fetch NAME [ARGS] [--force]` | Copies the files your `fetch` hook names from that worktree into your checkout. Refuses if your checkout's code differs from what was staged. |
| `runs` | Lists staged worktrees on the relay. |
| `drop NAME` | Removes a staged worktree and everything in it. |

## Configuration (`.veil/config`, sourced as bash)

| Variable | Default | Meaning |
|---|---|---|
| `RELAY_HOST` | (required) | SSH destination or alias |
| `RELAY_REPO` | (required) | Repo path on the relay (relative to `~` or absolute) |
| `RELAY_BRANCH` | `main` | Branch checked out on the relay |
| `RELAY_PUSH_REMOTE` | `origin` | Remote *on the relay* to push to; empty means never push |
| `RELAY_REMOTE` | `relay` | Name of the relay remote in your repo |
| `SOURCE_REMOTE` / `SOURCE_BRANCH` | `origin` / `main` | The reviewed branch that gets exported |
| `EXCLUDE` | `(.veil .github)` | Paths that never leave; the relay's own copy is kept |
| `DENYLIST` | `.veil/denylist` | Case-insensitive plain-text terms, one per line |
| `REQUIRE_TOGETHER` | `()` | Rules like `"src/model -> out/weights.bin"`: if the left side changes, every path on the right must change too, or export stops |
| `WARN_TOGETHER` | `()` | Same syntax, but only warns |
| `VERIFY_PATHS` | `()` | Run the verify hook only when these paths change; empty means every export (if the hook exists) |
| `NAMESPACE` | `veil` | Used for `refs/<ns>/*`, `~/.<ns>/` and `~/<ns>-runs` on the relay, and for local tags |
| `RUNS_DIR` | `<ns>-runs` | Where `stage` creates worktrees on the relay |
| `MAX_FILE_MB` | `95` | Block files larger than this |

Set `VEIL_SSH` to use something other than `ssh` (for example in tests), and
`VEIL_CONFIG` to point at a different config file.

## Hooks (`.veil/hooks/`)

Hooks are bash scripts kept in your repo. They are streamed to the relay when
needed and never committed there. Each one runs on the relay with the `env` hook
pasted in first, the worktree as its working directory, and these variables set:
`VEIL_WORKTREE`, `VEIL_COMMIT`, `VEIL_NAME` (stage/fetch) and `VEIL_KEEP_DIR`
(verify).

| Hook | Runs | Purpose |
|---|---|---|
| `env` | before every other hook | Activate a virtualenv or conda env, pin `PYTHONPATH` to `$VEIL_WORKTREE`, and so on |
| `verify` | during `export`, in a clean worktree of the candidate commit | A non-zero exit stops the export and leaves the relay untouched. Copy anything you want to keep into `$VEIL_KEEP_DIR`. |
| `run` | `stage --run` | Start the job. Background long jobs yourself (`nohup`, `tmux new -d`) or the SSH session waits for them. |
| `fetch` | `fetch` | Print `remote_path<TAB>local_path` lines. Remote paths are relative to the worktree. |

[`examples/ml-training/`](../examples/ml-training/.veil) has a full set for "train on
a GPU box, ship a checkpoint together with the code that produced it".

## A team workflow

1. Everyone works on branches in the private repo. `main` is protected and
   changes only through reviewed PRs.
2. To try something on the relay: `git veil stage exp-42 --run --env "LR=3e-4"`.
3. When a result is good, run `git veil fetch exp-42` on the same branch. That
   copies the artifacts, and the provenance check makes sure they belong to this
   code. Commit them and open a PR.
4. One person runs `git veil export` after merges. If the relay changed in the
   meantime, run `git veil pull` and merge the branch it creates first.

## Caveats

- **Content is the remaining leak.** git-veil hides metadata. It can't tell that
  a comment, a log line or a document identifies you unless the denylist
  catches it. Keep the denylist complete, and read anything written in prose
  before exporting it.
- **The relay host knows who logs in.** SSH logins (source IPs, key comments)
  are visible to whoever administers the relay.
- **It leaves traces on the relay:** `refs/<ns>/runs/*`, worktrees under
  `~/<ns>-runs` and verify output under `~/.<ns>/`. Pick a bland `NAMESPACE`.
- **Upstream sees one commit per export**, at the times you export.
- **Don't edit the relay checkout by hand.** Export refuses when it's dirty;
  `pull` is the way to bring relay-side commits home.
- **Have one exporter at a time.** Concurrent exports are detected (the relay
  checks its HEAD hasn't moved) but not queued.

## Prior art

- [Copybara](https://github.com/google/copybara) (Google) moves code between
  repositories with transformations and metadata scrubbing. It's the closest
  relative and much more general. It needs a JVM, and it pushes directly with
  credentials you hold.
- `git filter-repo --mailmap`, or a squash-merge mirror, rewrites identities
  before pushing. That needs credentials for the destination, and the
  destination's expected identity has to be faked rather than used.

git-veil is for the case where the destination's credentials and identity live
only on a host you can SSH into, and that host may also be where the heavy
compute runs.

## Development

```bash
make test   # end-to-end suite: mock relay, upstream and private remote; fake ssh
make lint   # shellcheck
```

## License

MIT
