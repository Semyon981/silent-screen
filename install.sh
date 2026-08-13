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

# 1. Install the executable, always overwriting any previous copy. Use a checkout
#    beside this script only when we were actually run from a file; when piped
#    (curl | bash) BASH_SOURCE is empty, and we must download rather than pick up
#    whatever stale silent-screen.sh happens to sit in the current directory.
mkdir -p "$bin_dir"
self="${BASH_SOURCE[0]:-}"       # empty when piped from stdin
src=""
[[ -n "$self" ]] && src="$(cd "$(dirname "$self")" && pwd)/silent-screen.sh"
if [[ -n "$src" && -f "$src" ]]; then
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

# 2. Ensure jq — silent-screen --chats parses Telegram's JSON with it.
#    Installed natively: jq ships as a single static binary, so we just drop the
#    right one into ~/.local/bin. No Homebrew, no sudo. Version and checksums are
#    pinned; a curl download carries no quarantine flag, so Gatekeeper stays quiet.
JQ_VERSION=1.8.2
if command -v jq >/dev/null 2>&1; then
	echo "jq         ok ($(command -v jq))"
else
	case "$(uname -m)" in
		arm64|aarch64) jq_arch=arm64; jq_sha=2d75340ba57a4b4b4c8708a21c2dc8e958a48aaa8bba13b27f77f6e4c0eca07e ;;
		x86_64|amd64)  jq_arch=amd64; jq_sha=e94b266e3c26690550006abe63152b782280f4e14374accdf04cbde844f00bc0 ;;
		*)             jq_arch="" ;;
	esac
	if [[ -z "$jq_arch" ]]; then
		echo "jq         MISSING — unknown arch $(uname -m); install jq by hand for --chats" >&2
	else
		jq_url="https://github.com/jqlang/jq/releases/download/jq-${JQ_VERSION}/jq-macos-${jq_arch}"
		jq_tmp="$(mktemp)"
		echo "jq         downloading ${JQ_VERSION} (${jq_arch})…"
		if ! curl -fsSL "$jq_url" -o "$jq_tmp"; then
			rm -f "$jq_tmp"
			echo "jq         download failed from $jq_url — --chats will not work" >&2
		# shasum is the macOS tool; sha256sum covers non-mac dev boxes.
		elif { command -v shasum >/dev/null 2>&1 && [[ "$(shasum -a 256 "$jq_tmp" | cut -d' ' -f1)" == "$jq_sha" ]]; } \
		  || { command -v sha256sum >/dev/null 2>&1 && [[ "$(sha256sum "$jq_tmp" | cut -d' ' -f1)" == "$jq_sha" ]]; }; then
			install -m 755 "$jq_tmp" "$bin_dir/jq"
			rm -f "$jq_tmp"
			# Ad-hoc sign so an unsigned arm64 binary is not killed on launch.
			command -v codesign >/dev/null 2>&1 && codesign -s - -f "$bin_dir/jq" >/dev/null 2>&1 || true
			echo "jq         installed  $bin_dir/jq"
		else
			rm -f "$jq_tmp"
			echo "jq         checksum mismatch — refusing to install, --chats will not work" >&2
		fi
	fi
fi

# 3. Scaffold the config once. TG_PROXY is left as a placeholder — fill in the
#    real relay line by hand so credentials never live in the repo or this script.
if [[ -e "$config" ]]; then
	echo "kept       $config (already exists)"
else
	mkdir -p "$config_dir"
	umask 177                          # the file is created 600
	cat > "$config" <<'EOF'
# silent-screen config. Keep this file 600.
TG_BOT_TOKEN=
# One or more recipients, comma- or space-separated: 987654321,-1001234567890
TG_CHAT_ID=
# Optional relay for networks that block api.telegram.org:
# TG_PROXY=socks5h://user:pass@host:1080
EOF
	echo "created    $config (fill in TG_BOT_TOKEN, then run: silent-screen --chats)"
fi

# 4. Make sure ~/.local/bin is on PATH; wire it into the login shell if not.
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
echo "  2. message your bot in Telegram, then: silent-screen --chats"
echo "  3. copy the printed id into TG_CHAT_ID, then: silent-screen"
