#!/bin/sh
# Fake backend for the specs: logs every call to $FAKE_LOG, serves $FAKE_THREADS.
echo "$*" >> "$FAKE_LOG"
threads() {
  if [ -f "$FAKE_THREADS.after" ] && grep -qE '^(submit|resolve|unresolve) ' "$FAKE_LOG"; then
    cat "$FAKE_THREADS.after"
  else
    cat "$FAKE_THREADS"
  fi
}
case "$1" in
  # The remote as it is once something was sent, if the spec gives one.
  threads) threads ;;
  # {mr, threads}: the MR from $FAKE_MR, or $FAKE_MR.<iid> for --mr=<iid>.
  threads-mr)
    mr="$FAKE_MR"
    case "$2" in --mr=*) [ -f "$FAKE_MR.${2#--mr=}" ] && mr="$FAKE_MR.${2#--mr=}" ;; esac
    printf '{"mr": %s, "threads": %s}\n' "$(cat "$mr")" "$(threads)" ;;
  # Each queued draft gets its own id: d1, d2, ...
  add|general|reply)
    body=$(cat); echo "stdin: $body" >> "$FAKE_LOG"
    echo "{\"id\": \"d$(grep -c '^stdin:' "$FAKE_LOG")\"}" ;;
  submit) echo "{\"published\": [\"$(echo "$2" | sed 's/,/","/g')\"]}" ;;
  # Publishes the first draft, then fails.
  partial) echo "{\"published\": [\"${2%%,*}\"]}"; echo "boom" >&2; exit 1 ;;
  fail) echo "boom" >&2; exit 1 ;;
  offline) echo "GitLab unreachable (gitlab.example.com): timed out" >&2; exit 3 ;;
  notgitlab) echo "github.com is not a GitLab server (HTTP 404 with text/html)" >&2; exit 6 ;;
  nomr) echo "No open MR for branch 'main' in g/p: !7 was merged (use --mr IID)." >&2; exit 5 ;;
  slow) sleep 5 ;;
  *) ;;
esac
