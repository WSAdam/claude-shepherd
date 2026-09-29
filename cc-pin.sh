#!/usr/bin/env bash
# cc-pin.sh - pin a few links to this session's card in Shepherd (build program unit 31, 2026-09-29).
#
#   cc-pin.sh add <link> [--label <text>]   pin a link (at most 8 per worktree); again = relabel
#   cc-pin.sh rm <link|number>              unpin one (by its link, its path, or the number list shows)
#   cc-pin.sh list                          this worktree's pins
#
# A link is an http(s) URL (a preview, a PR) or a file in this worktree: file:///absolute/path, or
# a plain path, resolved from the current folder. Pins belong to the WORKTREE (its git root), not
# the session: they live in ~/.claude/cc-pins/<encoded git root>.json, survive /clear and a
# respawn, and go when the worktree does (Shepherd verifies its merge, or its folder is gone).
# Shepherd shows them as chips on the card and in the detail panel; a click opens the link.
#
# Refused: anything but http(s) with a host or a file under the git root (its real path, symlinks
# followed); a link holding whitespace, a quote, a backslash, a control character or a shell
# metacharacter (| & ; ( ) < > ` $); a 9th pin. Nothing here or in Shepherd passes a link through a
# shell -- the refusals are defense in depth -- and Shepherd checks every link again before it
# opens it: http(s) in the browser, a file with /usr/bin/open given an argv. core.pinCheck
# (cc-core.lua) holds the same rules; tests/fixtures/pin-links.tsv holds both to one table.
# Exit codes: 0 done, 2 refused (the reason is printed).
set -u

# shellcheck source=cc-lib.sh
. "$(dirname "$0")/cc-lib.sh" 2>/dev/null || . "$HOME/.claude/cc-lib.sh"

PINS_MAX=8
URL_MAX=2000
LABEL_MAX=80
META_RE='[[:space:][:cntrl:]|&;()<>`$\"'"'"']'
HTTP_RE='^[Hh][Tt][Tt][Pp][Ss]?://[^[:space:]/]'

refuse() { echo "❌ cc-pin: $*"; exit 2; }
command -v jq >/dev/null 2>&1 || refuse "jq is required"
[ -n "${CLAUDE_CODE_SESSION_ID:-}" ] || refuse "not inside a Claude Code session (CLAUDE_CODE_SESSION_ID is unset)"

has_meta() { local LC_ALL=C; [[ "$1" =~ $META_RE ]]; }
has_ctl() { local LC_ALL=C; [[ "$1" =~ [[:cntrl:]] ]]; }
bytes() { local LC_ALL=C; printf '%s' "${#1}"; }

# The worktree: git's name for its root (the same string Shepherd's own git reads), and its real path.
GIT_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || GIT_ROOT=""
[ -n "$GIT_ROOT" ] || refuse "not inside a git repository -- pins belong to a worktree"
case "$GIT_ROOT" in /*) ;; *) refuse "git named no absolute root ($GIT_ROOT)" ;; esac
has_ctl "$GIT_ROOT" && refuse "the git root's path holds a control character"
REAL_ROOT="$(cd -- "$GIT_ROOT" 2>/dev/null && pwd -P)" || refuse "can't enter the git root $GIT_ROOT"
NAME="$(printf '%s' "$GIT_ROOT" | LC_ALL=C sed 's/[^A-Za-z0-9]/-/g')"   # core.pinFileName, byte for byte
[ "$(bytes "$NAME")" -le 250 ] || refuse "the git root's path is too long to name its pins file"
PINS_FILE="$CC_PINS_DIR/$NAME.json"

# Is the pins file this worktree's (or not there yet)? One another worktree wrote under the same
# name (/a/b-c and /a/b/c encode alike) is not, and is never changed from here.
ours() {
  [ -f "$PINS_FILE" ] || return 0
  local root
  root="$(jq -r 'if (.root | type) == "string" then .root else empty end' "$PINS_FILE" 2>/dev/null)"
  [ -z "$root" ] || [ "$root" = "$GIT_ROOT" ]
}
# This worktree's pins file as JSON ({} when there is none, or it isn't ours).
current() {
  { [ -f "$PINS_FILE" ] && ours; } || { printf '{}'; return 0; }
  jq -c 'if type == "object" then . else {} end' "$PINS_FILE" 2>/dev/null || printf '{}'
}

# Write <json> as this worktree's pins, atomically; no pins left takes the file with it.
save() { # <json>
  if [ "$(printf '%s' "$1" | jq '(.pins // []) | length')" -eq 0 ]; then rm -f "$PINS_FILE"; return 0; fi
  mkdir -p "$CC_PINS_DIR" && chmod 700 "$CC_PINS_DIR" 2>/dev/null
  local tmp="$PINS_FILE.tmp.$$"
  if printf '%s' "$1" | jq --arg root "$GIT_ROOT" '.v = 1 | .root = $root' > "$tmp" 2>/dev/null && mv "$tmp" "$PINS_FILE"; then
    return 0
  fi
  rm -f "$tmp"
  refuse "couldn't write $PINS_FILE"
}

# A link as the user gave it -> LINK_KIND (http|file) and LINK_URL (a file's is file://<real path>).
resolve_link() { # <arg>
  local a="$1" p real dir base
  [ -n "$a" ] || refuse "give a link: an http(s) URL, a file:// URL or a path"
  [ "$(bytes "$a")" -le "$URL_MAX" ] || refuse "the link is longer than $URL_MAX characters"
  if has_meta "$a"; then
    refuse "the link holds whitespace, a quote, a backslash, a control character or a shell metacharacter (| & ; ( ) < > \` \$) -- pin it without that part"
  fi
  if [[ "$a" =~ $HTTP_RE ]]; then LINK_KIND=http; LINK_URL="$a"; return 0; fi
  if [[ "$a" =~ ^[Ff][Ii][Ll][Ee]:// ]]; then
    p="${a#*://}"
    case "$p" in /*) ;; *) refuse "a file:// link names an absolute path (file:///path)" ;; esac
    case "$p" in *%*) refuse "a file:// link can't carry %-escapes -- give the path itself" ;; esac
    case "$p/" in */./*|*/../*) refuse "a file:// link can't hold . or .. segments" ;; esac
  elif [[ "$a" =~ ^[A-Za-z][A-Za-z0-9+.-]*: ]]; then
    refuse "only http(s) and file:// links can be pinned (a path with a colon: start it with ./)"
  else
    p="$a"
  fi
  [ -e "$p" ] || refuse "no such file: $p"
  if [ -d "$p" ]; then
    real="$(cd -- "$p" 2>/dev/null && pwd -P)" || refuse "can't enter $p"
  else
    [ -L "$p" ] && refuse "$p is a symlink -- pin the file it points to"
    dir="$(dirname -- "$p")"; base="$(basename -- "$p")"
    real="$(cd -- "$dir" 2>/dev/null && pwd -P)" || refuse "can't enter $dir"
    real="$real/$base"
  fi
  case "$real" in "$REAL_ROOT"|"$REAL_ROOT"/*) ;; *) refuse "$p isn't inside this worktree ($GIT_ROOT)" ;; esac
  has_meta "$real" && refuse "the file's real path ($real) holds whitespace, a quote or a shell metacharacter"
  LINK_KIND=file; LINK_URL="file://$real"
}

cmd_add() {
  local link="" label="" have=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --label) [ $# -ge 2 ] || refuse "--label takes a text"; label="$2"; shift 2 ;;
      --*) refuse "unknown option: $1" ;;
      *) [ -z "$have" ] || refuse "one link at a time"; link="$1"; have=1; shift ;;
    esac
  done
  [ -n "$have" ] || refuse "give a link: cc-pin.sh add <link> [--label <text>]"
  has_ctl "$label" && refuse "the label holds a control character"
  [ "$(bytes "$label")" -le "$LABEL_MAX" ] || refuse "the label is longer than $LABEL_MAX bytes"
  resolve_link "$link"
  local cur n known
  cur="$(current)"
  ours || refuse "$PINS_FILE holds another worktree's pins (a path that encodes to the same name) -- left alone"
  n="$(printf '%s' "$cur" | jq '(.pins // []) | length')"
  known="$(printf '%s' "$cur" | jq --arg u "$LINK_URL" '(.pins // []) | any(.url == $u)')"
  if [ "$known" != true ] && [ "$n" -ge "$PINS_MAX" ]; then
    refuse "this worktree already has $PINS_MAX pins -- unpin one first (cc-pin.sh list, then cc-pin.sh rm <number>)"
  fi
  save "$(printf '%s' "$cur" | jq -c --arg u "$LINK_URL" --arg k "$LINK_KIND" --arg l "$label" --argjson at "$(date +%s)" '
    .pins = (.pins // [])
    | if any(.pins[]; .url == $u) then .pins |= map(if .url == $u and $l != "" then .label = $l else . end)
      else .pins += [{url: $u, kind: $k, at: $at} + (if $l == "" then {} else {label: $l} end)] end')"
  n="$(jq '.pins | length' "$PINS_FILE")"
  if [ "$known" = true ]; then
    echo "📌 Already pinned: $LINK_URL${label:+ (now labelled \"$label\")} -- $n of $PINS_MAX."
  else
    echo "📌 Pinned ${label:+\"$label\" }$LINK_URL -- $n of $PINS_MAX. It shows as a chip on this session's card in Shepherd."
  fi
  exit 0
}

cmd_rm() {
  [ $# -eq 1 ] || refuse "give one pin: cc-pin.sh rm <link|path|number>"
  local arg="$1" cur n url=""
  cur="$(current)"
  ours || refuse "$PINS_FILE holds another worktree's pins -- left alone"
  n="$(printf '%s' "$cur" | jq '(.pins // []) | length')"
  if [[ "$arg" =~ ^[0-9]+$ ]]; then
    [ "$arg" -ge 1 ] && [ "$arg" -le "$n" ] || refuse "there is no pin $arg (this worktree has $n)"
    url="$(printf '%s' "$cur" | jq -r --argjson i "$arg" '.pins[$i - 1].url')"
  elif [ "$(printf '%s' "$cur" | jq --arg u "$arg" '(.pins // []) | any(.url == $u)')" = true ]; then
    url="$arg"
  else
    resolve_link "$arg"
    [ "$(printf '%s' "$cur" | jq --arg u "$LINK_URL" '(.pins // []) | any(.url == $u)')" = true ] \
      || refuse "$arg isn't pinned here (cc-pin.sh list shows what is)"
    url="$LINK_URL"
  fi
  save "$(printf '%s' "$cur" | jq -c --arg u "$url" '.pins = ((.pins // []) | map(select(.url != $u)))')"
  echo "✅ Unpinned $url -- $((n - 1)) of $PINS_MAX left."
  exit 0
}

cmd_list() {
  [ $# -eq 0 ] || refuse "list takes no arguments"
  local cur n
  cur="$(current)"
  ours || echo "⚠️ $PINS_FILE holds another worktree's pins (a path that encodes to the same name)."
  n="$(printf '%s' "$cur" | jq '(.pins // []) | length')"
  if [ "$n" -eq 0 ]; then echo "🔍 No pins for $GIT_ROOT."; exit 0; fi
  echo "📌 $n of $PINS_MAX pins for $GIT_ROOT:"
  printf '%s' "$cur" | jq -r '.pins | to_entries[] | "  \(.key + 1). \(if (.value.label // "") != "" then "\(.value.label) -- " else "" end)\(.value.url)"'
  exit 0
}

case "${1:-}" in
  add)  shift; cmd_add "$@" ;;
  rm)   shift; cmd_rm "$@" ;;
  list) shift; cmd_list "$@" ;;
  *) echo "usage: cc-pin.sh add <link> [--label <text>] | rm <link|path|number> | list"
     exit 2 ;;
esac
