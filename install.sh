#!/bin/bash
# Install silent-screen into ~/.local/bin and scaffold its config.
# Idempotent: rerun any time to update the installed copy. Never touches an
# existing config, so your token and proxy line survive a reinstall.
set -euo pipefail

raw_base="https://raw.githubusercontent.com/Semyon981/silent-screen/master"

bin_dir="${XDG_BIN_HOME:-$HOME/.local/bin}"
dest="$bin_dir/silent-screen"          # dropped .sh: it becomes a command name
config_dir="${XDG_CONFIG_HOME:-$HOME/.config}/silent-screen"
config="$config_dir/config"

# 1. Install the executable. Prefer a checkout beside this script (dev flow);
#    fall back to downloading from GitHub so `curl … | bash` works standalone.
mkdir -p "$bin_dir"
# BASH_SOURCE is unset when piped from stdin (curl | bash); :- keeps set -u quiet.
src_dir="$(cd "$(dirname "${BASH_SOURCE[0]:-}")" 2>/dev/null && pwd || true)"
src="$src_dir/silent-screen.sh"
if [[ -n "$src_dir" && -f "$src" ]]; then
	install -m 755 "$src" "$dest"
	echo "installed  $dest (from local checkout)"
else
	tmp="$(mktemp)"
	trap 'rm -f "$tmp"' EXIT
	curl -fsSL "$raw_base/silent-screen.sh" -o "$tmp" \
		|| { echo "install: failed to download silent-screen.sh from $raw_base" >&2; exit 1; }
	# Guard against a truncated download landing in PATH as a runnable command.
	head -1 "$tmp" | grep -q '^#!/bin/bash' \
		|| { echo "install: downloaded file is not the expected script" >&2; exit 1; }
	install -m 755 "$tmp" "$dest"
	echo "installed  $dest (downloaded)"
fi

# 2. Scaffold the config once. TG_PROXY is left as a placeholder — fill in the
#    real relay line by hand so credentials never live in the repo or this script.
if [[ -e "$config" ]]; then
	echo "kept       $config (already exists)"
else
	mkdir -p "$config_dir"
	umask 177                          # the file is created 600
	cat > "$config" <<'EOF'
# silent-screen config. Keep this file 600.
TG_BOT_TOKEN=
TG_CHAT_ID=
# Optional relay for networks that block api.telegram.org:
# TG_PROXY=socks5h://user:pass@host:1080
EOF
	echo "created    $config (fill in TG_BOT_TOKEN, then run: silent-screen --chat-id)"
fi

# 3. Make sure ~/.local/bin is on PATH; wire it into the login shell if not.
case ":$PATH:" in
	*":$bin_dir:"*) echo "PATH       ok ($bin_dir already on PATH)" ;;
	*)
		# zsh is the macOS default; fall back to bash's profile otherwise.
		case "${SHELL##*/}" in
			zsh)  profile="$HOME/.zprofile" ;;
			*)    profile="$HOME/.bash_profile" ;;
		esac
		line="export PATH=\"$bin_dir:\$PATH\""
		if [[ -f "$profile" ]] && grep -qF "$line" "$profile"; then
			echo "PATH       line already in $profile — open a new terminal"
		else
			printf '\n# added by silent-screen install.sh\n%s\n' "$line" >> "$profile"
			echo "PATH       added $bin_dir to $profile — open a new terminal or: source $profile"
		fi
		;;
esac

echo
echo "next:"
echo "  1. put your BotFather token in $config"
echo "  2. message your bot in Telegram, then: silent-screen --chat-id"
echo "  3. copy the printed id into TG_CHAT_ID, then: silent-screen"
