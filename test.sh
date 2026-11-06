#!/usr/bin/env bash

# Tests for dotfiles.sh. Each test runs in an isolated temp HOME with a local
# bare repository acting as the remote, so nothing touches the real $HOME.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DOTFILES="$SCRIPT_DIR/dotfiles.sh"

TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT

# Sanitize any inherited env vars that could redirect git or the script back to
# the real home. HOME / XDG_CONFIG_HOME / XDG_DATA_HOME /
# GIT_CONFIG_GLOBAL are set per-test.
unset ZSH_CUSTOM \
	GIT_DIR GIT_WORK_TREE GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES \
	GIT_TEMPLATE_DIR GIT_CONFIG GIT_CONFIG_COUNT GIT_CONFIG_GLOBAL 2>/dev/null || true

PASS=0
FAIL=0
COUNTER=0
OUT=""
REMOTE=""

# ----- ASSERTIONS -------------------------------------------------------------

function pass() {
	PASS=$((PASS + 1))
	printf '  \033[32m✓\033[0m %s\n' "$1"
}

function fail() {
	FAIL=$((FAIL + 1))
	printf '  \033[31m✗\033[0m %s\n' "$1"
	[ -n "${2:-}" ] && printf '      %s\n' "$2"
}

function assert_file() { [ -e "$1" ] && pass "$2" || fail "$2" "missing: $1"; }
function assert_no_file() { [ ! -e "$1" ] && pass "$2" || fail "$2" "should not exist: $1"; }
function assert_eq() { [ "$1" = "$2" ] && pass "$3" || fail "$3" "expected '$1', got '$2'"; }
function assert_contains() { grep -q -- "$2" "$1" 2>/dev/null && pass "$3" || fail "$3" "'$2' not found in $1"; }
function assert_not_contains() { ! grep -q -- "$2" "$1" 2>/dev/null && pass "$3" || fail "$3" "'$2' still in $1"; }
function assert_output_contains() { echo "$OUT" | grep -qi -- "$1" && pass "$2" || fail "$2" "output missing: $1"; }
function assert_tracked() { dot ls-files --error-unmatch "$1" &>/dev/null && pass "$2" || fail "$2" "not tracked: $1"; }
function assert_not_tracked() { ! dot ls-files --error-unmatch "$1" &>/dev/null && pass "$2" || fail "$2" "still tracked: $1"; }
function assert_remote_has() { git --git-dir="$REMOTE" ls-tree -r --name-only master 2>/dev/null | grep -q -- "$1" && pass "$2" || fail "$2" "remote missing: $1"; }
function assert_remote_empty() { ! git --git-dir="$REMOTE" rev-parse --verify -q master &>/dev/null && pass "$1" || fail "$1" "remote was unexpectedly updated"; }

# ----- HELPERS ----------------------------------------------------------------

# Run git against the dotfiles bare repo of the current sandbox home
function dot() { git --git-dir="$XDG_DATA_HOME/dotfiles" --work-tree="$HOME" "$@"; }

# Create an isolated home with a git identity, and point $HOME at it
function use_new_home() {
	COUNTER=$((COUNTER + 1))
	local home="$TEST_ROOT/home$COUNTER"
	mkdir -p "$home"
	git config --file "$home/.gitconfig" user.name "Test"
	git config --file "$home/.gitconfig" user.email "test@example.com"
	git config --file "$home/.gitconfig" init.defaultBranch master
	export HOME="$home"
	export XDG_CONFIG_HOME="$home/.config"
	export XDG_DATA_HOME="$home/.local/share"
	# force git to read only the sandbox config, never the real ~/.gitconfig or system
	export GIT_CONFIG_GLOBAL="$home/.gitconfig"
	export GIT_CONFIG_SYSTEM="/dev/null"
}

# Fresh sandbox: an isolated home plus a bare remote acting as the git remote.
# Sets $HOME (via use_new_home) and $REMOTE.
function sandbox() {
	use_new_home
	COUNTER=$((COUNTER + 1))
	REMOTE="$TEST_ROOT/remote$COUNTER.git"
	git init -q --bare "$REMOTE"
}

# Run dotfiles.sh, capturing combined output in $OUT. Stdin is inherited, so
# callers pipe answers to interactive prompts (repo URL, confirmations).
# Safety net: never invoke the script unless HOME is inside the sandbox, so a
# missed use_new_home can't touch the real home.
function run() {
	case "$HOME" in
	"$TEST_ROOT"/*) ;;
	*)
		printf '\033[31mABORT: HOME (%s) is not under TEST_ROOT — refusing to run\033[0m\n' "$HOME" >&2
		exit 1
		;;
	esac
	OUT="$(bash "$DOTFILES" "$@" 2>&1)"
}

function CONFIG() { echo "$XDG_CONFIG_HOME/dotfiles.conf"; }

# ----- TESTS ------------------------------------------------------------------

function test_add_initializes_and_tracks() {
	sandbox
	echo "rc content" >"$HOME/.myrc"

	run add "$HOME/.myrc" <<<"$REMOTE"

	assert_file "$XDG_DATA_HOME/dotfiles" "add inits the bare repo on first run"
	assert_file "$(CONFIG)" "add writes the config file"
	assert_contains "$(CONFIG)" '.myrc' "config lists the added file"
	assert_tracked "$HOME/.myrc" "added file is tracked by git"
}

function test_config_uses_home_placeholder() {
	sandbox
	echo x >"$HOME/.myrc"

	run add "$HOME/.myrc" <<<"$REMOTE"

	assert_contains "$(CONFIG)" '^\$HOME/.myrc$' "config stores path with \$HOME placeholder, not absolute"
}

function test_push_updates_remote() {
	sandbox
	echo "content" >"$HOME/.myrc"
	run add "$HOME/.myrc" <<<"$REMOTE"

	run push <<<"Y"

	assert_remote_has '.myrc' "pushed file appears on the remote"
}

function test_rm_untracks_and_updates_config() {
	sandbox
	echo x >"$HOME/.myrc"
	run add "$HOME/.myrc" <<<"$REMOTE"

	run rm "$HOME/.myrc"

	assert_not_tracked "$HOME/.myrc" "removed file is no longer tracked"
	assert_not_contains "$(CONFIG)" '.myrc' "removed file is dropped from config"
}

function test_pull_roundtrip() {
	# Machine A: add + push
	sandbox
	echo "hello from A" >"$HOME/.foorc"
	run add "$HOME/.foorc" <<<"$REMOTE"
	run push <<<"Y"

	# Machine B: fresh home, same remote, pull
	use_new_home
	run pull <<<"$REMOTE"$'\nY'

	assert_file "$HOME/.foorc" "pull brings the file onto a second machine"
	assert_eq "hello from A" "$(cat "$HOME/.foorc" 2>/dev/null)" "pulled file keeps its content"
}

function test_add_missing_file_warns() {
	sandbox

	run add "$HOME/.does_not_exist" <<<"$REMOTE"

	assert_not_tracked "$HOME/.does_not_exist" "missing file is not tracked"
	assert_output_contains "not found" "add warns about the missing file"
}

function test_add_is_idempotent() {
	sandbox
	echo x >"$HOME/.myrc"

	run add "$HOME/.myrc" <<<"$REMOTE"
	run add "$HOME/.myrc" # second time: repo already inited, no prompt

	assert_eq "1" "$(grep -c '.myrc' "$(CONFIG)")" "adding the same file twice keeps one config entry"
}

function test_rm_deleted_file() {
	sandbox
	echo x >"$HOME/.myrc"
	run add "$HOME/.myrc" <<<"$REMOTE"
	command rm "$HOME/.myrc"

	run rm "$HOME/.myrc"

	assert_not_tracked "$HOME/.myrc" "file deleted from disk is no longer tracked"
	assert_not_contains "$(CONFIG)" '.myrc' "file deleted from disk is dropped from config"
}

function test_rm_file_whose_deletion_was_pushed() {
	sandbox
	echo x >"$HOME/.myrc"
	run add "$HOME/.myrc" <<<"$REMOTE"
	run push <<<"Y"
	command rm "$HOME/.myrc"
	run push <<<"Y"

	run rm "$HOME/.myrc"

	assert_not_contains "$(CONFIG)" '.myrc' "file whose deletion was pushed is dropped from config"
	assert_eq "0" "$(echo "$OUT" | grep -ci 'not tracked')" "rm does not warn about a file listed in config"
}

function test_rm_untracked_warns() {
	sandbox
	echo x >"$HOME/.tracked"
	run add "$HOME/.tracked" <<<"$REMOTE"
	echo y >"$HOME/.untracked"

	run rm "$HOME/.untracked"

	assert_output_contains "not tracked" "rm warns when the file is not tracked"
}

function test_push_cancel_leaves_remote_untouched() {
	sandbox
	echo x >"$HOME/.myrc"
	run add "$HOME/.myrc" <<<"$REMOTE"

	run push <<<"n"

	assert_remote_empty "cancelled push leaves the remote untouched"
}

function test_pull_cancel_leaves_files_untouched() {
	# Machine A: publish a file
	sandbox
	echo "hello" >"$HOME/.foorc"
	run add "$HOME/.foorc" <<<"$REMOTE"
	run push <<<"Y"

	# Machine B: pull but answer no
	use_new_home
	run pull <<<"$REMOTE"$'\nn'

	assert_no_file "$HOME/.foorc" "cancelled pull does not write any file"
}

function test_paths_with_spaces() {
	sandbox
	local f="$HOME/my file.rc"
	echo x >"$f"

	run add "$f" <<<"$REMOTE"
	assert_tracked "$f" "file with spaces is tracked"
	assert_contains "$(CONFIG)" 'my file.rc' "config stores file with spaces"

	run rm "$f"
	assert_not_tracked "$f" "file with spaces can be removed"
}

# ----- RUN --------------------------------------------------------------------

# Auto-discover and run every test_* function, printing its name as a header
for fn in $(compgen -A function | grep '^test_'); do
	printf '\033[1m%s\033[0m\n' "$fn"
	"$fn"
done

echo
printf 'Passed: \033[32m%d\033[0m  Failed: \033[31m%d\033[0m\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
