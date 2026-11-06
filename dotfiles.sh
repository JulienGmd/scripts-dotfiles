#!/usr/bin/env bash

set -uo pipefail

# ----- PARAMS -----------------------------------------------------------------

DIR_GIT="${XDG_DATA_HOME:-$HOME/.local/share}/dotfiles"
FILE_CONFIG="${XDG_CONFIG_HOME:-$HOME/.config}/dotfiles.conf"
DIR_COMPLETIONS="${ZSH_CUSTOM:-$HOME/.oh-my-zsh/custom}/completions"
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
	echo_error "$1"
	if [[ -n "${2+x}" ]]; then echo_debug "$2" >&2; fi # ${2+x}: "x" if $2 is set (even empty), "" if unset; prevents crash with set -u
	exit 1
}

# ----- REQUIREMENTS -----------------------------------------------------------

if ! command -v git &>/dev/null; then exit_error "Please install git."; fi

# ----- HELPERS ----------------------------------------------------------------

# Using a bare git repository to manage files in $HOME
function git_cmd() { git --git-dir="$DIR_GIT" --work-tree="$HOME" "$@"; }

function is_in_array() {
	local thing="$1"
	shift
	for item in "$@"; do
		[[ "$item" == "$thing" ]] && return 0
	done
	return 1
}

function remove_from_array() {
	local thing="$1"
	local -n _arr="$2" # alias (pointer) to the array
	local result=()
	for item in "${_arr[@]}"; do
		[[ "$item" != "$thing" ]] && result+=("$item")
	done
	_arr=("${result[@]}") # this sets the original array passed as argument
}

# ----- FILES TO SYNC MANAGEMENT -----------------------------------------------

function load_files_to_sync() {
	FILES_TO_SYNC=()

	[ ! -f "$FILE_CONFIG" ] && return

	while IFS= read -r line; do
		[[ -z "$line" ]] && continue
		FILES_TO_SYNC+=("${line/#\$HOME/$HOME}") # expand $HOME
	done <"$FILE_CONFIG"
}

function save_files_to_sync() {
	mkdir -p "$(dirname "$FILE_CONFIG")"
	printf '%s\n' "${FILES_TO_SYNC[@]/#$HOME/\$HOME}" >"$FILE_CONFIG" # escape $HOME
}

function add_file_to_sync() {
	local file="$(realpath -m "$1")"
	load_files_to_sync
	is_in_array "$file" "${FILES_TO_SYNC[@]}" && return
	FILES_TO_SYNC+=("$file")
	save_files_to_sync
}

function remove_file_to_sync() {
	local file="$(realpath -m "$1")"
	load_files_to_sync
	remove_from_array "$file" FILES_TO_SYNC
	save_files_to_sync
}

# ----- MAIN COMMANDS ----------------------------------------------------------

function init() {
	[ -d "$DIR_GIT" ] && exit_error "Dotfiles repository already exists at $DIR_GIT."

	# Ask for git repo name
	read -rp "Enter the git repository URL for your dotfiles (e.g. git@github.com:<user>/<repo>.git): " REPO_URL
	[[ -z "$REPO_URL" ]] && exit_error "Please provide a repository URL."

	local ls_remote_err ls_remote_rc
	ls_remote_err=$(git ls-remote "$REPO_URL" 2>&1 >/dev/null); ls_remote_rc=$?
	[ $ls_remote_rc -ne 0 ] && ! grep -q "Repository not found" <<<"$ls_remote_err" \
		&& exit_error "Failed to access $REPO_URL:" "$ls_remote_err"

	mkdir -p "$DIR_GIT"
	git init --bare "$DIR_GIT" || exit_error "Failed to init repository."
	git_cmd remote add origin "$REPO_URL" || exit_error "Failed to add remote."

	# don't show untracked files since home is cluttered
	echo_debug "Configuring git..."
	git_cmd config --local status.showUntrackedFiles no

	[ $ls_remote_rc -eq 0 ] && echo_info "Remote repository found. Run 'pull' to fetch your dotfiles."
}

function add() {
	[ ! -d "$DIR_GIT" ] && init

	echo_debug "Adding files..."
	for file in "$@"; do
		file="$(realpath -m "$file")"
		if [ ! -e "$file" ]; then
			echo_warning "File not found: $file"
			continue
		fi
		git_cmd add -v "$file"
		add_file_to_sync "$file"
	done
}

function rm() {
	[ ! -d "$DIR_GIT" ] && init

	echo_debug "Removing files..."
	for file in "$@"; do
		file="$(realpath -m "$file")"
		load_files_to_sync
		if git_cmd ls-files --error-unmatch "$file" &>/dev/null; then
			git_cmd rm --cached -r "$file"
		elif ! is_in_array "$file" "${FILES_TO_SYNC[@]}"; then
			echo_warning "File not tracked: $file"
			continue
		fi
		remove_file_to_sync "$file"
	done
}

function pull() {
	[ ! -d "$DIR_GIT" ] && init

	echo_debug "Fetching changes from remote..."
	git_cmd fetch origin +master:refs/remotes/origin/master

	if ! git_cmd rev-parse --verify origin/master &>/dev/null; then
		echo_debug "No remote branch yet"
		return
	fi

	echo_debug "Displaying incoming changes..."
	# first pull after init has no local commit yet, so diff against an empty tree
	local base="HEAD"
	git_cmd rev-parse --verify -q HEAD &>/dev/null || base="$(git_cmd hash-object -t tree /dev/null)"
	git_cmd diff "$base" origin/master
	read -rp "Do you want to apply these changes? [Y/n]: " confirm_pull
	confirm_pull=${confirm_pull:-Y}
	if [[ "$confirm_pull" != [yY] ]]; then
		echo_info "Pull cancelled."
		return
	fi

	echo_debug "Pulling changes from remote..."
	git_cmd reset --hard origin/master
}

function push() {
	[ ! -d "$DIR_GIT" ] && init

	# 1. add
	echo_debug "Staging changes..."
	git_cmd add -uv # stage modified/deleted tracked files
	load_files_to_sync
	for file in "${FILES_TO_SYNC[@]}"; do
		git_cmd add -v "$file" # stage new files and directories that are in FILES_TO_SYNC
	done
	[ -f "$FILE_CONFIG" ] && git_cmd add "$FILE_CONFIG" # stage dotfiles config

	# 2. display diff and ask confirm
	echo_debug "Displaying staged changes..."
	git_cmd diff --cached
	read -rp "Do you want to commit and push these changes? [Y/n]: " confirm_push
	confirm_push=${confirm_push:-Y}
	if [[ "$confirm_push" != [yY] ]]; then
		echo_info "Push cancelled."
		return
	fi

	# 3. commit
	echo_debug "Committing changes..."
	git_cmd commit -m "dotfiles auto commit"

	# 4. create remote repo if it doesn't exist
	if ! git_cmd ls-remote origin &>/dev/null; then
		# Extract repo name from origin URL
		local origin_url="$(git_cmd config --get remote.origin.url)"
		local repo_name="$(basename "$origin_url" .git)"
		if command -v gh &>/dev/null; then
			# Ask if user wants to create a private repo
			read -rp "Remote repository not found. Do you want to create a private repository on GitHub? [Y/n]: " create_repo
			create_repo=${create_repo:-Y}
			[[ "$create_repo" != [yY] ]] && exit_error "Please create it manually (expected repo name: $repo_name)."
			# create repo using GitHub CLI
			local gh_err
			gh_err=$(gh repo create "$repo_name" --private 2>&1) || exit_error "Failed to create GitHub repository." "$gh_err"
			echo_info "Repository created successfully."
		else
			exit_error "Push failed. Remote repository may not exist. Please create it manually (expected repo name: $repo_name) or install GitHub CLI (gh) to create it automatically."
		fi
	fi

	# 5. push
	echo_debug "Pushing changes to remote..."
	local push_err
	push_err=$(git_cmd push --force -u origin master 2>&1) || exit_error "Failed to push to remote repository." "$push_err"
}

function completions() {
	mkdir -p "$DIR_COMPLETIONS"
	cat >"$DIR_COMPLETIONS/_dotfiles" <<'EOF'
#compdef dotfiles

_dotfiles() {
  local -a commands=(
    'help:Display this help message'
    'add:Add FILE(s) to be tracked'
    'rm:Remove FILE(s) from being tracked'
    'push:Push changes'
    'pull:Pull changes'
    'git:Run a git command on the dotfiles repository'
    'completions:Install zsh completions'
  )

  if (( CURRENT == 2 )); then
    _describe 'command' commands
  elif (( CURRENT > 2 )); then
    case $words[2] in
      add) _files -F words ;;
      rm) compadd -F words -- ${(f)"$(dotfiles git ls-files 2>/dev/null)"} ;;
      git) local -x GIT_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/dotfiles" GIT_WORK_TREE="$HOME"; words=(git ${words[3,-1]}); (( CURRENT-- )); _normal ;;
    esac
  fi
}

_dotfiles "$@"
EOF
	echo_info "Completions installed. Restart your shell or run: exec zsh"
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
	echo "  completions         Install zsh completions"
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
	completions)
		completions
		;;
	*)
		echo_error "Unknown command: $1"
		usage
		exit 1
		;;
	esac
}

main "$@"
