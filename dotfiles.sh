#!/usr/bin/env bash

set -euo pipefail

# ----- PARAMS -----------------------------------------------------------------

DIR_GIT="$HOME/.dotfiles"
FILE_CONFIG="${XDG_CONFIG_HOME:-$HOME/.config}/dotfiles.conf"
GRAY="\033[90m"
YELLOW="\033[33m"
RED="\033[31m"
NC="\033[0m"

# ----- HELPERS ----------------------------------------------------------------

function echo_info() { echo -e "$1"; }
function echo_debug() { echo -e "$GRAY$1$NC"; }
function echo_warning() { echo -e "$YELLOW$1$NC" >&2; }
function echo_error() { echo -e "$RED$1$NC" >&2; }
function exit_error() {
	set +u
	echo_error "$1"
	if [[ -n "${2+x}" ]]; then echo_debug "$2" >&2; fi
	exit 1
}

# ----- REQUIREMENTS -----------------------------------------------------------

if ! command -v git &>/dev/null; then exit_error "Please install git."; fi

# ----- HELPERS ----------------------------------------------------------------

# We are using a bare git repository to manage dotfiles in $HOME
function git_cmd() { git --git-dir="$DIR_GIT" --work-tree="$HOME" "$@"; }

function is_in_array() {
	local thing="$1"
	shift
	local arr=("$@")
	for item in "${arr[@]}"; do
		if [[ "$item" == "$thing" ]]; then return 0; fi
	done
	return 1
}

function ensure_readme() {
	local readme_content
	readme_content=$(
		cat <<'EOF'
# Dotfiles

This repository is managed by the dotfiles.sh script.

Download it at: https://github.com/JulienGmd/scripts-dotfiles
EOF
	)

	# Create/Update README.md directly in the git index without a working-tree file
	local blob_hash
	blob_hash=$(printf '%s\n' "$readme_content" | git_cmd hash-object -w --stdin)
	printf '100644 %s\t%s\n' "$blob_hash" "README.md" | git_cmd update-index --add --index-info
	if git_cmd ls-files --error-unmatch -- "README.md" &>/dev/null; then
		git_cmd update-index --skip-worktree -- "README.md" || true
	fi
}

# ----- FILES TO SYNC MANAGEMENT -----------------------------------------------

function load_files_to_sync() {
	FILES_TO_SYNC=()

	if [ ! -f "$FILE_CONFIG" ]; then return; fi

	while IFS= read -r line; do
		if [[ -z "$line" ]]; then continue; fi
		FILES_TO_SYNC+=("${line/#\$HOME/$HOME}") # expand $HOME
	done <"$FILE_CONFIG"
}

function save_files_to_sync() {
	mkdir -p "$(dirname "$FILE_CONFIG")"
	printf '%s\n' "${FILES_TO_SYNC[@]/#$HOME/\$HOME}" >"$FILE_CONFIG" # escape $HOME
}

function add_file_to_sync() {
	local file
	file="$(realpath "$1")"
	load_files_to_sync
	if is_in_array "$file" "${FILES_TO_SYNC[@]}"; then return; fi
	FILES_TO_SYNC+=("$file")
	save_files_to_sync
}

function remove_file_to_sync() {
	local file
	file="$(realpath "$1")"
	load_files_to_sync
	local new_array=() # rebuild new array to prevent empty entries
	for item in "${FILES_TO_SYNC[@]}"; do
		if [[ "$item" != "$file" ]]; then new_array+=("$item"); fi
	done
	FILES_TO_SYNC=("${new_array[@]}")
	save_files_to_sync
}

# ----- MAIN COMMANDS ----------------------------------------------------------

function init() {
	if [ -d "$DIR_GIT" ]; then return; fi

	# Ask for git repo name
	read -rp "Enter the git repository URL for your dotfiles (e.g. git@github.com:username/dotfiles.git): " REPO_URL
	if [[ -z "$REPO_URL" ]]; then exit_error "Repository URL cannot be empty."; fi

	set +e
	local ls_remote_err
	ls_remote_err=$(git ls-remote "$REPO_URL" 2>&1 >/dev/null)
	if [ $? -eq 0 ]; then
		# repo found, clone it
		git clone --bare "$REPO_URL" "$DIR_GIT"
	elif grep -q "Repository not found" <<<"$ls_remote_err"; then
		# repo not found, create a new one
		mkdir -p "$DIR_GIT"
		git init --bare "$DIR_GIT"
		git_cmd remote add origin "$REPO_URL"
	else
		# error occurred (repo probably inaccessible)
		exit_error "Failed to access $REPO_URL." "$ls_remote_err"
	fi
	set -e

	# don't show untracked files since home is cluttered
	git_cmd config --local status.showUntrackedFiles no
}

function add() {
	if [ ! -d "$DIR_GIT" ]; then init; fi

	for file in "$@"; do
		file="$(realpath "$file")"
		if [ ! -e "$file" ]; then
			echo_warning "File not found: $file"
			continue
		fi
		git_cmd add -v "$file"
		add_file_to_sync "$file"
	done
}

function rm() {
	if [ ! -d "$DIR_GIT" ]; then init; fi

	for file in "$@"; do
		file="$(realpath "$file")"
		if ! git_cmd ls-files --error-unmatch "$file" &>/dev/null; then
			echo_warning "File not tracked: $file"
			continue
		fi
		git_cmd rm --cached -r "$file"
		remove_file_to_sync "$file"
	done
}

function pull() {
	if [ ! -d "$DIR_GIT" ]; then init; fi

	git_cmd fetch origin master

	if ! git_cmd rev-parse --verify origin/master &>/dev/null; then
		echo_debug "No remote branch yet"
		return
	fi

	git_cmd reset --hard origin/master
}

function push() {
	if [ ! -d "$DIR_GIT" ]; then init; fi

	ensure_readme

	# 1. add
	git_cmd update-index --assume-unchanged "$HOME/README.md" || true # ignore root README.md so it's not removed
	git_cmd add -uv                                                   # stage modified/deleted tracked files
	load_files_to_sync
	for file in "${FILES_TO_SYNC[@]}"; do
		git_cmd add -v "$file" # stage new files and directories that are in FILES_TO_SYNC
	done
	git_cmd add "$FILE_CONFIG" # stage dotfiles config

	# 2. display diff and ask confirm
	git_cmd diff --cached
	read -rp "Do you want to commit and push these changes? [Y/n]: " confirm_push
	confirm_push=${confirm_push:-Y}
	if [[ "$confirm_push" != [yY] ]]; then
		echo_info "Push cancelled."
		return
	fi

	# 3. commit
	git_cmd commit -m "dotfiles auto commit" || true

	# 4. create remote repo if it doesn't exist
	if ! git_cmd ls-remote origin &>/dev/null; then
		if command -v gh &>/dev/null; then
			# Ask if user wants to create a private repo
			read -rp "Remote repository not found. Do you want to create a private repository on GitHub? [Y/n]: " create_repo
			create_repo=${create_repo:-Y}
			if [[ "$create_repo" != [yY] ]]; then
				exit_error "Push failed. Remote repository may not exist. Please create it manually."
			fi
			# Extract repo name from origin URL
			local origin_url
			origin_url=$(git_cmd config --get remote.origin.url)
			local repo_name
			repo_name=$(basename "$origin_url" .git)
			# create repo using GitHub CLI
			gh repo create "$repo_name" --private || exit_error "Failed to create GitHub repository."
			echo_info "Repository created successfully."
		else
			exit_error "Push failed. Remote repository may not exist. Please create it manually or install GitHub CLI (gh) to create it automatically."
		fi
	fi

	# 5. push
	git_cmd push -u origin master || exit_error "Failed to push to remote repository."

}

function usage() {
	echo "Usage: $(basename "$0") COMMAND [ARGS]"
	echo
	echo "Commands:"
	echo "  help                Display this help message"
	echo "  add FILE...         Add FILE(s) to be tracked"
	echo "  rm FILE...          Remove FILE(s) from being tracked"
	echo "  push                Push changes"
	echo "  pull                Pull changes"
	echo "  git GIT_COMMAND...  Run a git command on the dotfiles repository"
}

# ----- ENTRY POINT ------------------------------------------------------------

function main() {
	if [ $# -eq 0 ]; then
		usage
		exit 0
	fi

	case "$1" in
	help)
		usage
		exit 0
		;;
	add)
		shift
		add "$@"
		;;
	rm)
		shift
		rm "$@"
		;;
	pull)
		pull
		;;
	push)
		push
		;;
	git)
		shift
		git_cmd "$@"
		;;
	*)
		echo_error "Unknown command: $1"
		usage
		exit 1
		;;
	esac
}

main "$@"
