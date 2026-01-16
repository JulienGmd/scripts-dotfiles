#!/usr/bin/env bash

DIR="$(dirname "$(realpath "$0")")"
COMPLETIONS_DIR="$ZSH_CUSTOM/completions"

mkdir -p "$COMPLETIONS_DIR"
cp -f "$DIR/_dotfiles" "$COMPLETIONS_DIR/"
