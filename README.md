# git-veil

Work in your own repo with your own history. Publish anonymous snapshots through a host whose git identity you don't control.

```
your repo ──git veil export──▶ relay host ──push──▶ upstream
    ▲                              │
    └──── git veil pull ◀──────────┘
```

Only file snapshots cross. Each commit is created **on the relay**, with the relay's own name, email and clock. Your authors, messages, branches and PRs never leave your repo.

## Install

```bash
git clone https://github.com/1mach0/git-veil && cd git-veil && make install
```

Needs bash ≥ 4.4 and git. On macOS, run `brew install bash` first. The relay only needs git and bash.

## Use

```bash
# .veil/config
RELAY_HOST=my-server        # ssh alias
RELAY_REPO=path/to/repo     # repo path on the relay

git veil init               # once
git veil export -m "Update" # ship origin/main
```

| Command | Does |
|---|---|
| `init` | Record the starting point |
| `status` | Show what export would send |
| `export` | One snapshot, one relay commit, then push upstream |
| `pull` | Bring relay-side changes home as a branch |
| `stage NAME --run` | Run any branch in its own worktree on the relay |
| `fetch NAME` | Copy results back, only if they match your code |
| `runs` / `drop NAME` | List / remove staged worktrees |

Before anything leaves your machine, export checks for leaks (a denylist scan, binaries included), refuses to overwrite changes made on the relay, and can run your `verify` hook in a clean checkout first.

Docs: [reference](docs/reference.md) · [example config](examples/ml-training/.veil)

## License

MIT
