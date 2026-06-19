# dotfiles.sh

A small, dependency-free script to manage your dotfiles with a **bare git
repository** in `$HOME` — no symlinks, no extra tooling. Files are tracked
where they already live.

## How it works

`dotfiles.sh` drives a bare repository at `~/.dotfiles` with the work tree set
to `$HOME`. The list of files you track is kept in
`${XDG_CONFIG_HOME:-~/.config}/dotfiles.conf`, with `$HOME` stored as a
placeholder so the config is portable across machines.

Sync model is **last-write-wins**, which keeps the workflow simple:

- `push` stages your tracked files, shows the diff, asks for confirmation, then
  commits and force-pushes.
- `pull` fetches the remote, shows the incoming diff, asks for confirmation,
  then hard-resets your local files to match.

## Install

```sh
git clone https://github.com/JulienGmd/scripts-dotfiles.git
# put the script on your PATH as `dotfiles`
ln -s "$PWD/scripts-dotfiles/dotfiles.sh" ~/.local/bin/dotfiles
```

Requires `git` (and `gh` only if you want a private GitHub repo created
automatically on first push).

## Usage

```
dotfiles add FILE...   Track FILE(s)
dotfiles rm FILE...    Stop tracking FILE(s)
dotfiles push          Commit and push tracked files (with confirmation)
dotfiles pull          Fetch and apply remote changes (with confirmation)
dotfiles git ...       Run any git command against the dotfiles repo
dotfiles completions   Install zsh completions
dotfiles help          Show usage
```

On the first command, the script asks for your dotfiles repository URL and
initializes `~/.dotfiles`. If the remote already has commits, run `pull` to
fetch them.

### Example

```sh
dotfiles add ~/.zshrc ~/.config/nvim
dotfiles push

# on another machine, after install:
dotfiles pull
```

## Zsh completions

```sh
dotfiles completions   # writes to $ZSH_CUSTOM/completions/_dotfiles
exec zsh
```

Completion is aware of the bare repo: `add` completes any file (with normal
filesystem navigation), `rm` completes only tracked files, and `git` falls
through to git's own completion.

## Tests

```sh
bash test.sh
```

The suite runs each scenario in an isolated temporary `$HOME` with a local bare
repo standing in for the remote, so it never touches your real home.
