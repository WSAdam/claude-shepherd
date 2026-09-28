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
#   @@commitsess<TAB><transcript><TAB><ISO time><TAB><branch><TAB><short sha><TAB><subject>
#
# The @@commitsess lines come last: every "[branch sha] subject" that `git commit` printed into
# a Bash tool result, in the transcripts touched since <epoch>, with that record's timestamp and
# the subject still JSON-escaped. core.commitWeek matches them to commits by subject and author
# time, so each commit links to the session that made it without a word in its message. A grep
# over the records, never a JSON decode: ripgrep when installed (~0.3s over 900MB of
# transcripts), else grep (~5s). CC_COMMITS_ENGINE=grep forces the fallback (the tests use it).
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

# Which session made each commit: what `git commit` printed ("[feat/x 1a2b3c4] subject",
# "[detached HEAD 05f0943] ...", "[main (root-commit) 0123abc] ...") inside a tool result, in
# every transcript (subagents' too) written since <epoch>. A record carries its output twice
# (message.content and toolUseResult.stdout), so one line prints once. An assistant merely
# quoting such a line is not a tool result and doesn't count.
commit_sessions() {
  [ -d "$projects" ] || return 0
  local now mins engine re
  now="$(date +%s)"
  mins=$(( (now - since) / 60 + 2 ))
  [ "$mins" -gt 0 ] || mins=1
  re='\[[^]\\" ]+( [^]\\" ]+)? [0-9a-f]{7,40}\] '
  engine="${CC_COMMITS_ENGINE:-}"
  if [ -z "$engine" ]; then
    if command -v rg >/dev/null 2>&1; then engine=rg; else engine=grep; fi
  fi
  local scan
  if [ "$engine" = rg ]; then
    scan=(rg --no-config --no-messages --no-heading --with-filename --no-line-number -e "$re")
  else
    scan=(env LC_ALL=C grep -H -E -e "$re")
  fi
  find "$projects" -type f -name '*.jsonl' -mmin "-$mins" -exec "${scan[@]}" {} + 2>/dev/null |
    LC_ALL=C awk '{
      i = index($0, ".jsonl:")
      if (i == 0) next
      path = substr($0, 1, i + 5); body = substr($0, i + 7)
      if (index(body, "\"tool_result\"") == 0) next
      if (!match(body, /"timestamp":"[^"]*"/)) next
      ts = substr(body, RSTART + 13, RLENGTH - 14)
      split("", seen)
      s = body
      while (match(s, /\[[^]\\" ]+( [^]\\" ]+)? [0-9a-f]{7,40}\] ([^\\"]|\\[^n])*/)) {
        m = substr(s, RSTART, RLENGTH); s = substr(s, RSTART + RLENGTH)
        cb = index(m, "] ")
        n = split(substr(m, 2, cb - 2), part, " ")
        branch = part[1]
        for (k = 2; k < n; k++) if (part[k] != "(root-commit)") branch = branch " " part[k]
        key = branch "\t" part[n] "\t" substr(m, cb + 2)
        if (key in seen) continue
        seen[key] = 1
        print "@@commitsess\t" path "\t" ts "\t" key
      }
    }' | LC_ALL=C sort -u | head -n 5000
}
commit_sessions
exit 0
