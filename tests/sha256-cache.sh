#!/bin/sh
set -eu

repo_dir=$(CDPATH= cd "$(dirname "$0")/.." && pwd)
test_dir=$(mktemp -d)
trap 'rm -rf "$test_dir"' EXIT HUP INT TERM

# Load only the two functions; sourcing the menu would run its Entware entry point.
eval "$(sed -n '/^ensure_blobs_sha256sums() {/,/^}/p; /^ensure_repo_sha256sums() {/,/^}/p' "$repo_dir/nfqws-menu.sh")"

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

download_file() {
  download_calls=$((download_calls + 1))
  case "$2" in "$cache".tmp.*) ;; *) fail "download target is not beside $cache" ;; esac
  rm -f "$2"
  case "$download_result" in
    fail) printf 'partial\n' > "$2"; return 1 ;;
    success) printf 'new\n' > "$2" ;;
    empty) : > "$2" ;;
  esac
}

check_cache() {
  expected=$1
  [ "$(cat "$cache")" = "$expected" ] || fail "$function_name: expected $expected cache"
}

check_no_tmp() {
  for leftover in "$cache".tmp.*; do
    [ ! -e "$leftover" ] && [ ! -L "$leftover" ] || fail "$function_name: temporary file remains"
  done
}

for function_name in ensure_blobs_sha256sums ensure_repo_sha256sums; do
  cache="$test_dir/$function_name"
  BLOBS_SHA256SUMS_CACHE=$cache
  REPO_SHA256SUMS_CACHE=$cache
  BLOBS_SHA256SUMS_URL=https://example.invalid/blobs
  REPO_SHA256SUMS_URL=https://example.invalid/repo

  printf 'old\n' > "$cache"
  download_calls=0
  download_result=fail
  "$function_name" || fail "$function_name: fresh cache rejected"
  [ "$download_calls" -eq 0 ] || fail "$function_name: fresh cache downloaded"
  check_cache old

  touch -t 200001010000 "$cache"
  "$function_name" || fail "$function_name: stale cache rejected after download failure"
  [ "$download_calls" -eq 1 ] || fail "$function_name: stale cache did not try download"
  check_cache old
  check_no_tmp

  download_result=success
  "$function_name" || fail "$function_name: successful download rejected"
  [ "$download_calls" -eq 2 ] || fail "$function_name: stale cache did not refresh"
  check_cache new
  check_no_tmp

  rm -f "$cache"
  download_result=fail
  if "$function_name"; then fail "$function_name: missing cache accepted after download failure"; fi
  [ ! -e "$cache" ] || fail "$function_name: partial download became cache"
  check_no_tmp

  printf 'old\n' > "$cache"
  touch -t 200001010000 "$cache"
  download_result=empty
  "$function_name" || fail "$function_name: empty download discarded stale cache"
  check_cache old
  check_no_tmp
  printf 'PASS: %s\n' "$function_name"
done
