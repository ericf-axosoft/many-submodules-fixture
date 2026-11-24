#!/usr/bin/env bash
# Build a superproject with many local submodules in a realistic mix of states.
# Usage: make-subm-repo.sh <target-dir> [submodule-count=40] [files-per-submodule=100]
# Offline: every remote is a local bare repo. Re-running wipes <target-dir>.
set -euo pipefail

TARGET=${1:?usage: make-subm-repo.sh <target-dir> [count] [files]}
COUNT=${2:-40}
FILES=${3:-100}
(( COUNT >= 10 )) || { echo "count must be >= 10 (the last 10 get special states)"; exit 1; }
(( FILES >= 1 )) || { echo "files-per-submodule must be >= 1"; exit 1; }

export GIT_AUTHOR_NAME=Test GIT_AUTHOR_EMAIL=test@example.com
export GIT_COMMITTER_NAME=Test GIT_COMMITTER_EMAIL=test@example.com
G() { git -c protocol.file.allow=always -c init.defaultBranch=main -c core.autocrlf=false "$@"; }

rm -rf "$TARGET"
mkdir -p "$TARGET/remotes"
TARGET=$(cd "$TARGET" && pwd)
REMOTES="$TARGET/remotes"

name() { printf 'sub%02d' "$1"; }

echo "Creating $COUNT submodule remotes with $FILES files each..."
for i in $(seq 1 "$COUNT"); do
  n=$(name "$i")
  G init -q --bare "$REMOTES/$n.git"
  seed="$TARGET/seed-$n"
  G init -q "$seed"
  mkdir -p "$seed/src"
  for f in $(seq 1 "$FILES"); do printf 'file %d of %s\n' "$f" "$n" > "$seed/src/f$f.txt"; done
  G -C "$seed" add -A && G -C "$seed" commit -qm "Initial $n"
  echo v2 >> "$seed/src/f1.txt" && G -C "$seed" commit -qam "Second $n"
  G -C "$seed" push -q "$REMOTES/$n.git" main
  rm -rf "$seed"
done

echo "Creating superproject..."
SUPER="$TARGET/super"
G init -q --bare "$REMOTES/super.git"
G init -q "$SUPER"
echo "superproject" > "$SUPER/README.md"
G -C "$SUPER" add README.md && G -C "$SUPER" commit -qm "Initial super"
for i in $(seq 1 "$COUNT"); do
  n=$(name "$i")
  G -C "$SUPER" submodule add -q "$REMOTES/$n.git" "subs/$n"
done
G -C "$SUPER" commit -qm "Add $COUNT submodules"
G -C "$SUPER" remote add origin "$REMOTES/super.git"
G -C "$SUPER" push -q -u origin main
# Let later submodule fetches, from git or a Git client, use the local file remotes.
G -C "$SUPER" config protocol.file.allow always

# The last 10 submodules get special states; the rest stay clean.
s() { echo "$SUPER/subs/$(name $(( COUNT - 10 + $1 )))"; }

# 1-2: dirty work tree (modified tracked file; untracked file)
echo dirty >> "$(s 1)/src/f1.txt"
echo new > "$(s 2)/untracked.txt"

# 3-4: submodule HEAD moved away from the recorded pointer (not staged)
for k in 3 4; do echo moved >> "$(s $k)/src/f1.txt"; G -C "$(s $k)" commit -qam "Local move"; done
# 4 also gets a staged pointer change
G -C "$SUPER" add "subs/$(basename "$(s 4)")"

# 5: ahead of its upstream by 2 commits (pointer also out of sync)
for c in 1 2; do echo "ahead $c" >> "$(s 5)/src/f1.txt"; G -C "$(s 5)" commit -qam "Ahead $c"; done

# 6: behind its upstream by 1 commit
other="$TARGET/other-clone"
G clone -q "$REMOTES/$(basename "$(s 6)").git" "$other"
echo upstream >> "$other/src/f1.txt" && G -C "$other" commit -qam "Upstream change"
G -C "$other" push -q origin main
rm -rf "$other"
G -C "$(s 6)" fetch -q origin

# 7: diverged (ahead 1 and behind 1)
other="$TARGET/other-clone"
G clone -q "$REMOTES/$(basename "$(s 7)").git" "$other"
echo upstream >> "$other/src/f1.txt" && G -C "$other" commit -qam "Upstream change"
G -C "$other" push -q origin main
rm -rf "$other"
echo local >> "$(s 7)/src/f1.txt" && G -C "$(s 7)" commit -qam "Local change"
G -C "$(s 7)" fetch -q origin

# 8: not initialized
G -C "$SUPER" submodule deinit -q -f "subs/$(basename "$(s 8)")"

# 9: submodule folder deleted from disk
rm -rf "$(s 9)"

# 10: clean but detached HEAD at the recorded commit
G -C "$(s 10)" checkout -q --detach

# Root work tree change, so the root status has something to report.
echo "root change" >> "$SUPER/README.md"

echo
echo "Done: $SUPER"
G -C "$SUPER" status --short
