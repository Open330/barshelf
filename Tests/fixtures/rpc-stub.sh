#!/bin/bash
# JSON-RPC protocol stub — stands in for the deno script runtime in tests.
#
# Speaks newline-delimited JSON-RPC 2.0 over stdio, exactly like a script
# widget: reads host notifications from stdin, issues host.* requests on
# stdout, and reads the host's responses back from stdin.
#
# Usage: rpc-stub.sh <scenario>
#   render       widget.load → host.render (text "hello from stub")
#   exec-denied  widget.load → host.exec.run "rm -rf /" → expects -32001 →
#                renders "denied -32001"
#   exec-ok      widget.load → host.exec.run "echo hi" (parse text) →
#                renders "exec-ok <response marker>"
#   storage      widget.load → host.storage.set/get roundtrip → renders
#                "storage-ok" when the value came back intact
#   secret       widget.load → host.secret.set/get roundtrip → renders result
#   timer        widget.load → host.timer.after 100ms → on widget.timer
#                renders "timer-fired"
#   log          widget.load → host.log → renders "logged"
#   crash        exits 1 immediately
#
# The host encodes with sorted JSON keys, so substring matching on
# '"method":"widget.load"' etc. is deterministic.

scenario="${1:-render}"
next_id=1

send() { printf '%s\n' "$1"; }

# Sends a request and reads the host's response line into $resp.
request() {
  send "$1"
  IFS= read -r resp
}

render() { # $1 = text to render
  request "{\"jsonrpc\":\"2.0\",\"id\":$next_id,\"method\":\"host.render\",\"params\":{\"root\":{\"type\":\"text\",\"text\":\"$1\"}}}"
  next_id=$((next_id + 1))
}

if [ "$scenario" = "crash" ]; then
  exit 1
fi

handle_load() {
  case "$scenario" in
    render)
      render "hello from stub"
      ;;
    exec-denied)
      request "{\"jsonrpc\":\"2.0\",\"id\":$next_id,\"method\":\"host.exec.run\",\"params\":{\"command\":\"rm\",\"args\":[\"-rf\",\"/\"]}}"
      next_id=$((next_id + 1))
      case "$resp" in
        *'"code":-32001'*) render "denied -32001" ;;
        *) render "unexpected: no permission error" ;;
      esac
      ;;
    exec-ok)
      request "{\"jsonrpc\":\"2.0\",\"id\":$next_id,\"method\":\"host.exec.run\",\"params\":{\"command\":\"echo\",\"args\":[\"hi\"],\"parse\":\"text\"}}"
      next_id=$((next_id + 1))
      case "$resp" in
        *'"exitCode":0'*'"stdout":"hi\n"'*) render "exec-ok hi" ;;
        *'"stdout":"hi\n"'*) render "exec-ok hi" ;;
        *) render "unexpected exec response" ;;
      esac
      ;;
    storage)
      request "{\"jsonrpc\":\"2.0\",\"id\":$next_id,\"method\":\"host.storage.set\",\"params\":{\"key\":\"count\",\"value\":{\"n\":41}}}"
      next_id=$((next_id + 1))
      request "{\"jsonrpc\":\"2.0\",\"id\":$next_id,\"method\":\"host.storage.get\",\"params\":{\"key\":\"count\"}}"
      next_id=$((next_id + 1))
      case "$resp" in
        *'"n":41'*) render "storage-ok" ;;
        *) render "unexpected storage response" ;;
      esac
      ;;
    secret)
      request "{\"jsonrpc\":\"2.0\",\"id\":$next_id,\"method\":\"host.secret.set\",\"params\":{\"key\":\"token\",\"value\":\"s3cret\"}}"
      next_id=$((next_id + 1))
      case "$resp" in
        *'"code":-32001'*)
          render "secret-denied -32001"
          return
          ;;
      esac
      request "{\"jsonrpc\":\"2.0\",\"id\":$next_id,\"method\":\"host.secret.get\",\"params\":{\"key\":\"token\"}}"
      next_id=$((next_id + 1))
      case "$resp" in
        *'"result":"s3cret"'*) render "secret-ok" ;;
        *) render "unexpected secret response" ;;
      esac
      ;;
    timer)
      request "{\"jsonrpc\":\"2.0\",\"id\":$next_id,\"method\":\"host.timer.after\",\"params\":{\"id\":\"t1\",\"delayMs\":100}}"
      next_id=$((next_id + 1))
      render "timer-armed"
      ;;
    log)
      request "{\"jsonrpc\":\"2.0\",\"id\":$next_id,\"method\":\"host.log\",\"params\":{\"level\":\"info\",\"message\":\"hello log\"}}"
      next_id=$((next_id + 1))
      render "logged"
      ;;
  esac
}

handle_timer() {
  render "timer-fired"
}

while IFS= read -r line; do
  case "$line" in
    *'"method":"widget.load"'*) handle_load ;;
    *'"method":"widget.timer"'*) handle_timer ;;
    *'"method":"widget.action"'*) render "action-received" ;;
  esac
done
