# many-submodules-fixture

Builds a Git superproject with many submodules, in every state a Git client has to show, so you can
test and measure how a client handles them. Everything is local: each submodule's remote is a bare
repository next to the superproject, so no network or account is needed.

## Build it

Needs Git and Bash (Git Bash on Windows).

```bash
./make-subm-repo.sh <target-dir> [submodule-count=40] [files-per-submodule=100]
```

For example `./make-subm-repo.sh ./subm40` creates:

- `subm40/remotes/` with one bare repository per submodule, plus one for the superproject.
- `subm40/super/`, the superproject to open in your Git client.

Running it again wipes `<target-dir>` and builds it from scratch. With 40 submodules it takes about
two minutes on a slow Windows machine, mostly spent starting `git` processes.

## What is in it

Every submodule starts as a clone of its remote at its second commit. The first `count - 10` stay
clean. The last ten each get one state (with the default 40, those are `sub31` to `sub40`):

| Submodule | State |
|---|---|
| 1st of the last ten | A tracked file is modified (dirty) |
| 2nd | An untracked file is added (dirty) |
| 3rd | HEAD moved one commit past the commit the superproject records |
| 4th | HEAD moved, and the new commit is staged in the superproject |
| 5th | Two local commits ahead of its upstream branch |
| 6th | One commit behind its upstream branch (after a fetch) |
| 7th | Diverged: one commit ahead and one behind its upstream |
| 8th | Not initialized (`git submodule deinit`) |
| 9th | Folder deleted from disk |
| 10th | Detached HEAD at the recorded commit, otherwise clean |

The superproject's `README.md` is also modified, so the superproject itself has a change to show.

## Useful checks

Count every git process a command starts, including the ones git starts itself, with trace2:

```bash
mkdir trace && GIT_TRACE2_EVENT="$PWD/trace" git -C subm40/super status && ls trace | wc -l
```

A plain `git status` in the superproject starts one extra `git status` inside every initialized
submodule, to see whether it has changes.

## Build output inside a submodule

`repro-ignored-build-events.js` shows a related trap. A recursive file watcher on the superproject
also reports files that a submodule's own `.gitignore` ignores, such as build output. A client that
filters watcher events only with the superproject's root `.gitignore` refreshes on every build step
inside a submodule, even though `git status` sees nothing.

```bash
npm install
node repro-ignored-build-events.js subm40/super subs/sub05
```

It commits a `.gitignore` with `build/` in the given submodule, starts a watcher on the superproject
(2 second debounce), writes files into the submodule's `build/` for 12 seconds, and prints how many
event batches would still count as a change with and without the submodule's own `.gitignore`.

A second trap shows up when the build creates its output folder: on Windows the watcher also
reports the folder itself, by its bare path without a trailing slash. A pattern such as `build/`
only matches a path ending in a slash, so a filter has to try both `path` and `path/`. The script
does; delete the `build/` folder before running it to see that case.
