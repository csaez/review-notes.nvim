#!/bin/sh
# Fake backend for the specs: logs every call to $FAKE_LOG, serves $FAKE_THREADS.
echo "$*" >> "$FAKE_LOG"
case "$1" in
  threads) cat "$FAKE_THREADS" ;;
  add|reply) body=$(cat); echo "stdin: $body" >> "$FAKE_LOG"; echo '{"id": "d1"}' ;;
  submit) body=$(cat); echo "stdin: $body" >> "$FAKE_LOG" ;;
  fail) echo "boom" >&2; exit 3 ;;
  *) ;;
esac
