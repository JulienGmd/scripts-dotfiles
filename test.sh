#!/usr/bin/env bash

# Tests for dotfiles.sh. Each test runs in an isolated temp HOME with a local
# bare repository acting as the remote, so nothing touches the real $HOME.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DOTFILES="$SCRIPT_DIR/dotfiles.sh"

TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT

# Sanitize any inherited env vars that could redirect git or the script back to
# the real home. HOME / XDG_CONFIG_HOME / GIT_CONFIG_GLOBAL are set per-test.
unset ZSH_CUSTOM \
	GIT_DIR GIT_WORK_TREE GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES \
	GIT_TEMPLATE_DIR GIT_CONFIG GIT_CONFIG_COUNT GIT_CONFIG_GLOBAL 2>/dev/null || true

PASS=0
FAIL=0
COUNTER=0

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

function assert_tracked() {
	git --git-dir="$HOME/.dotfiles" --work-tree="$HOME" ls-files --error-unmatch "$1" &>/dev/null \
		&& pass "$2" || fail "$2" "not tracked: $1"
}
function assert_not_tracked() {
	! git --git-dir="$HOME/.dotfiles" --work-tree="$HOME" ls-files --error-unmatch "$1" &>/dev/null \
		&& pass "$2" || fail "$2" "still tracked: $1"
}

# ----- HELPERS ----------------------------------------------------------------

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
	# force git to read only the sandbox config, never the real ~/.gitconfig or system
	export GIT_CONFIG_GLOBAL="$home/.gitconfig"
	export GIT_CONFIG_SYSTEM="/dev/null"
}

# Create a bare repo to act as a remote, echo its path
function new_remote() {
	COUNTER=$((COUNTER + 1))
	local remote="$TEST_ROOT/remote$COUNTER.git"
	git init -q --bare "$remote"
	echo "$remote"
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

CONFIG() { echo "$XDG_CONFIG_HOME/dotfiles.conf"; }

# ----- TESTS ------------------------------------------------------------------

function test_add_initializes_and_tracks() {
	echo "test_add_initializes_and_tracks"
	use_new_home
	local remote; remote="$(new_remote)"
	echo "rc content" >"$HOME/.myrc"

	run add "$HOME/.myrc" <<<"$remote"

	assert_file "$HOME/.dotfiles" "add inits the bare repo on first run"
	assert_file "$(CONFIG)" "add writes the config file"
	assert_contains "$(CONFIG)" '.myrc' "config lists the added file"
	assert_tracked "$HOME/.myrc" "added file is tracked by git"
}

function test_config_uses_home_placeholder() {
	echo "test_config_uses_home_placeholder"
	use_new_home
	local remote; remote="$(new_remote)"
	echo x >"$HOME/.myrc"

	run add "$HOME/.myrc" <<<"$remote"

	assert_contains "$(CONFIG)" '^\$HOME/.myrc$' "config stores path with \$HOME placeholder, not absolute"
}

function test_push_updates_remote() {
	echo "test_push_updates_remote"
	use_new_home
	local remote; remote="$(new_remote)"
	echo "content" >"$HOME/.myrc"
	run add "$HOME/.myrc" <<<"$remote"

	run push <<<"Y"

	git --git-dir="$remote" ls-tree -r --name-only master 2>/dev/null | grep -q '.myrc' \
		&& pass "pushed file appears on the remote" || fail "pushed file appears on the remote"
}

function test_rm_untracks_and_updates_config() {
	echo "test_rm_untracks_and_updates_config"
	use_new_home
	local remote; remote="$(new_remote)"
	echo x >"$HOME/.myrc"
	run add "$HOME/.myrc" <<<"$remote"

	run rm "$HOME/.myrc"

	assert_not_tracked "$HOME/.myrc" "removed file is no longer tracked"
	assert_not_contains "$(CONFIG)" '.myrc' "removed file is dropped from config"
}

function test_pull_roundtrip() {
	echo "test_pull_roundtrip"
	# Machine A: add + push
	use_new_home
	local remote; remote="$(new_remote)"
	echo "hello from A" >"$HOME/.foorc"
	run add "$HOME/.foorc" <<<"$remote"
	run push <<<"Y"

	# Machine B: fresh home, same remote, pull
	use_new_home
	run pull <<<"$remote"$'\nY'

	assert_file "$HOME/.foorc" "pull brings the file onto a second machine"
	assert_eq "hello from A" "$(cat "$HOME/.foorc" 2>/dev/null)" "pulled file keeps its content"
}

function test_add_missing_file_warns() {
	echo "test_add_missing_file_warns"
	use_new_home
	local remote; remote="$(new_remote)"

	run add "$HOME/.does_not_exist" <<<"$remote"

	assert_not_tracked "$HOME/.does_not_exist" "missing file is not tracked"
	echo "$OUT" | grep -qi "not found" \
		&& pass "add warns about the missing file" || fail "add warns about the missing file"
}

function test_add_is_idempotent() {
	echo "test_add_is_idempotent"
	use_new_home
	local remote; remote="$(new_remote)"
	echo x >"$HOME/.myrc"

	run add "$HOME/.myrc" <<<"$remote"
	run add "$HOME/.myrc" # second time: repo already inited, no prompt

	assert_eq "1" "$(grep -c '.myrc' "$(CONFIG)")" "adding the same file twice keeps one config entry"
}

function test_rm_untracked_warns() {
	echo "test_rm_untracked_warns"
	use_new_home
	local remote; remote="$(new_remote)"
	echo x >"$HOME/.tracked"
	run add "$HOME/.tracked" <<<"$remote"
	echo y >"$HOME/.untracked"

	run rm "$HOME/.untracked"

	echo "$OUT" | grep -qi "not tracked" \
		&& pass "rm warns when the file is not tracked" || fail "rm warns when the file is not tracked"
}

function test_push_cancel_leaves_remote_untouched() {
	echo "test_push_cancel_leaves_remote_untouched"
	use_new_home
	local remote; remote="$(new_remote)"
	echo x >"$HOME/.myrc"
	run add "$HOME/.myrc" <<<"$remote"

	run push <<<"n"

	git --git-dir="$remote" rev-parse --verify -q master &>/dev/null \
		&& fail "cancelled push must not update the remote" \
		|| pass "cancelled push leaves the remote untouched"
}

function test_pull_cancel_leaves_files_untouched() {
	echo "test_pull_cancel_leaves_files_untouched"
	# Machine A: publish a file
	use_new_home
	local remote; remote="$(new_remote)"
	echo "hello" >"$HOME/.foorc"
	run add "$HOME/.foorc" <<<"$remote"
	run push <<<"Y"

	# Machine B: pull but answer no
	use_new_home
	run pull <<<"$remote"$'\nn'

	assert_no_file "$HOME/.foorc" "cancelled pull does not write any file"
}

function test_paths_with_spaces() {
	echo "test_paths_with_spaces"
	use_new_home
	local remote; remote="$(new_remote)"
	local f="$HOME/my file.rc"
	echo x >"$f"

	run add "$f" <<<"$remote"
	assert_tracked "$f" "file with spaces is tracked"
	assert_contains "$(CONFIG)" 'my file.rc' "config stores file with spaces"

	run rm "$f"
	assert_not_tracked "$f" "file with spaces can be removed"
}

# ----- RUN --------------------------------------------------------------------

test_add_initializes_and_tracks
test_config_uses_home_placeholder
test_push_updates_remote
test_rm_untracks_and_updates_config
test_pull_roundtrip
test_add_missing_file_warns
test_add_is_idempotent
test_rm_untracked_warns
test_push_cancel_leaves_remote_untouched
test_pull_cancel_leaves_files_untouched
test_paths_with_spaces

echo
printf 'Passed: \033[32m%d\033[0m  Failed: \033[31m%d\033[0m\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
