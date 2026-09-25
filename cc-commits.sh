#!/usr/bin/env bash
# cc-commits.sh - the git side of Shepherd's commit stats (Today / This week under the fleet
# block).
#
#   cc-commits.sh --since <epoch> [--lookback-days <n>] [--email <addr>]... [--projects-dir <dir>]
#
# Lists every git repo a Claude session worked in -- the cwd at the top of each transcript
# under ~/.claude/projects touched in the last <n> days (default 14), resolved to its main
# checkout -- then prints, per repo, the user's OWN commits since <epoch> with their line
# counts. Whose commits: that repo's `git config user.email` (so a repo-local or includeIf
# identity wins) plus every --email alias. Nothing about the user is hardcoded, so each
# install counts its own user. Read-only: git log / rev-parse / config, never a write.
#
# Output, parsed by core.parseCommitLog:
#   @@repo<TAB><main checkout><TAB><email,email>   one per repo; no emails = no identity, no log
#   \x01<sha><TAB><author epoch><TAB><author email><TAB><subject>
#   <added><TAB><deleted><TAB><path>               git --numstat ("-" for a binary file)
#
# Shepherd runs it in an hs.task with stdout redirected to a scratch file (a pipe deadlocks
# past ~64KB). Exit 2 on a bad argument.
set -u
export PATH="/opt/homebrew/bin:/usr/local/bin:${PATH:-/usr/bin:/bin}"

since=""
lookback=14
projects="$HOME/.claude/projects"
extra=()
while [ $# -gt 0 ]; do
  case "$1" in
    --since) since="${2:-}"; shift 2 ;;
    --lookback-days) lookback="${2:-}"; shift 2 ;;
    --email) [ -n "${2:-}" ] && extra+=("$2"); shift 2 ;;
    --projects-dir) projects="${2:-}"; shift 2 ;;
    *) echo "cc-commits.sh: unknown argument: $1" >&2; exit 2 ;;
  esac
done
case "$since" in ''|*[!0-9]*) echo "cc-commits.sh: --since <epoch> is required" >&2; exit 2 ;; esac
case "$lookback" in ''|*[!0-9]*) lookback=14 ;; esac

# The main checkout of every repo a transcript's cwd sits in. A cwd whose worktree has since
# been removed (.claude/worktrees/<slug>) still names its repo: fall back to the path above it.
repo_roots() {
  [ -d "$projects" ] || return 0
  find "$projects" -mindepth 2 -maxdepth 2 -name '*.jsonl' -mtime "-$lookback" 2>/dev/null |
    while IFS= read -r f; do
      head -c 65536 "$f" 2>/dev/null | grep -o '"cwd":"[^"]*"' | head -n 1
    done |
    sed -e 's/^"cwd":"//' -e 's/"$//' -e 's#\\/#/#g' | sort -u |
    while IFS= read -r dir; do
      [ -n "$dir" ] || continue
      if [ ! -d "$dir" ]; then
        case "$dir" in */.claude/worktrees/*) dir="${dir%%/.claude/worktrees/*}" ;; esac
      fi
      [ -d "$dir" ] || continue
      common="$(git -C "$dir" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" || continue
      case "$common" in */.git) printf '%s\n' "${common%/.git}" ;; esac   # a bare repo has no checkout
    done | sort -u
}

repo_roots | while IFS= read -r root; do
  emails=()
  own="$(git -C "$root" config --get user.email 2>/dev/null)"
  [ -n "$own" ] && emails+=("$own")
  for e in ${extra[@]+"${extra[@]}"}; do emails+=("$e"); done
  joined=""
  for e in ${emails[@]+"${emails[@]}"}; do joined="${joined:+$joined,}$e"; done
  printf '@@repo\t%s\t%s\n' "$root" "$joined"
  [ -n "$joined" ] || continue
  authors=()
  for e in "${emails[@]}"; do authors+=("--author=$e"); done
  # --all spans every worktree's branch (they share one repo's refs); a stash and git notes are
  # commits too, so they're left out. -F -i: each address is a fixed string, any case (git ORs
  # the --author flags); core.commitWeek then insists on an exact address.
  git -C "$root" log --exclude=refs/stash --exclude='refs/notes/*' --all --no-merges \
    --since="@$since" -F -i "${authors[@]}" --numstat \
    --format='%x01%H%x09%at%x09%ae%x09%s' 2>/dev/null
done
exit 0
