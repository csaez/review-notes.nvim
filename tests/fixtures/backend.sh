#!/bin/sh
# Fake backend for the specs: logs every call to $FAKE_LOG, serves $FAKE_THREADS.
echo "$*" >> "$FAKE_LOG"
case "$1" in
  # The remote as it is once something was sent, if the spec gives one.
  threads)
    if [ -f "$FAKE_THREADS.after" ] && grep -qE '^(submit|resolve|unresolve) ' "$FAKE_LOG"; then
      cat "$FAKE_THREADS.after"
    else
      cat "$FAKE_THREADS"
    fi ;;
  # Each queued draft gets its own id: d1, d2, ...
  add|general|reply)
    body=$(cat); echo "stdin: $body" >> "$FAKE_LOG"
    echo "{\"id\": \"d$(grep -c '^stdin:' "$FAKE_LOG")\"}" ;;
  submit) echo "{\"published\": [\"$(echo "$2" | sed 's/,/","/g')\"]}" ;;
  # Publishes the first draft, then fails.
  partial) echo "{\"published\": [\"${2%%,*}\"]}"; echo "boom" >&2; exit 3 ;;
  fail) echo "boom" >&2; exit 3 ;;
  *) ;;
esac
