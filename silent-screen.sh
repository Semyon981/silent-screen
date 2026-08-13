#!/bin/bash
# silent-screen — capture the screen and push it to a Telegram chat.
#
# Config: ~/.config/silent-screen/config  (chmod 600)
#   TG_BOT_TOKEN=123456:AA...
#   TG_CHAT_ID=987654321
#   TG_PROXY=socks5h://127.0.0.1:1080   # optional, for throttled networks
#   TG_API=https://api.telegram.org     # optional, override for a relay
#   TG_SEND_AS=photo                    # optional: photo (default) | document
#
# Runs silently: no sound, no on-screen notification, nothing that reveals a
# capture was taken. Failures go to stderr only (invisible when key-bound).
#
# Usage:
#   silent-screen.sh                     full main display
#   silent-screen.sh -i                  interactive selection (drag a region)
#   silent-screen.sh -w                  click a window to capture it
#   silent-screen.sh --chats             list chats that messaged the bot
#   silent-screen.sh --set KEY=VALUE ..  write config keys (creates the file)
#   silent-screen.sh --edit              open the config in $EDITOR
#   silent-screen.sh --config            print the config path

set -euo pipefail

CONFIG="${XDG_CONFIG_HOME:-$HOME/.config}/silent-screen/config"

die() {
	# stderr only — a GUI notification would defeat the point of the tool.
	printf 'silent-screen: %s\n' "$1" >&2
	exit 1
}

# Upsert KEY=VALUE lines, preserving the rest. Values are written verbatim, so
# slashes and colons in a proxy URL need no escaping (no sed involved).
config_set() {
	[[ $# -gt 0 ]] || die "usage: silent-screen --set KEY=VALUE [KEY=VALUE ...]"
	mkdir -p "$(dirname "$CONFIG")"
	(umask 177; touch "$CONFIG")
	for pair in "$@"; do
		[[ "$pair" == *=* ]] || die "expected KEY=VALUE, got: $pair"
		local key=${pair%%=*}
		[[ -n "$key" ]] || die "empty key in: $pair"
		local tmp; tmp="$(mktemp)"
		grep -vE "^[[:space:]]*${key}=" "$CONFIG" > "$tmp" 2>/dev/null || true
		printf '%s\n' "$pair" >> "$tmp"
		mv "$tmp" "$CONFIG"
	done
	chmod 600 "$CONFIG"
	echo "updated $CONFIG"
}

# Config-editing subcommands: usable before a complete config exists, so they
# run ahead of the readability check below.
case "${1:-}" in
	--set)    shift; config_set "$@"; exit 0 ;;
	--edit)   mkdir -p "$(dirname "$CONFIG")"; (umask 177; touch "$CONFIG")
	          exec "${EDITOR:-vi}" "$CONFIG" ;;
	--config) echo "$CONFIG"; exit 0 ;;
esac

[[ -r "$CONFIG" ]] || die "no config at $CONFIG — create it with: silent-screen --set TG_BOT_TOKEN=... TG_CHAT_ID=..."
# shellcheck source=/dev/null
source "$CONFIG"
: "${TG_BOT_TOKEN:?TG_BOT_TOKEN missing in config}"

api="${TG_API:-https://api.telegram.org}/bot${TG_BOT_TOKEN}"

curl_opts=(-sS --connect-timeout 10 --max-time 60)
[[ -n "${TG_PROXY:-}" ]] && curl_opts+=(--proxy "$TG_PROXY")

if [[ "${1:-}" == "--chats" ]]; then
	command -v jq >/dev/null 2>&1 || die "jq not found — rerun install.sh to fetch it"
	# Have the user message the bot first — getUpdates is empty until then.
	updates="$(curl "${curl_opts[@]}" "${api}/getUpdates")"
	# One row per distinct chat:  id  type  @username  name.
	rows="$(
		printf '%s' "$updates" | jq -r '
			if .ok == false then error(.description // "getUpdates failed") else . end
			| [ .result[]?
			    | (.message // .edited_message // .channel_post // {}).chat
			    | select(. != null) ]
			| unique_by(.id)[]
			| [ (.id | tostring),
			    (.type // "?"),
			    (if .username then "@" + .username else "-" end),
			    ((.title // ([.first_name, .last_name] | map(select(.)) | join(" ")))
			     | if . == "" then "-" else . end)
			  ] | @tsv
		'
	)" || die "could not parse Telegram response"
	[[ -n "$rows" ]] || die "no chats yet — message the bot in Telegram first"
	printf '%s\n' "$rows"
	exit 0
fi

: "${TG_CHAT_ID:?TG_CHAT_ID missing in config — run --chats to find it}"

# screencapture flags: -x silences the shutter sound, -o drops window shadows.
capture_flags=(-x -o)
case "${1:-}" in
	-i) capture_flags+=(-i) ;;          # drag a region
	-w) capture_flags+=(-iW) ;;         # click a window
	# Pinned to display 1: given several displays and one output path,
	# screencapture writes one file per display and we would only send the first.
	'') capture_flags+=(-D 1) ;;
	*)  die "unknown option: $1" ;;
esac

shot="$(mktemp -t silent-screen)".png
trap 'rm -f "$shot"' EXIT

screencapture "${capture_flags[@]}" "$shot"

# -i / -iW let the user press Esc, which leaves no file behind.
[[ -s "$shot" ]] || exit 0

name="$(date +%Y-%m-%d_%H.%M.%S).png"

# photo: shows inline in the chat, but Telegram re-encodes it to JPEG (text gets
# a little soft). document: sent as-is, lossless PNG, appears as an attachment.
case "${TG_SEND_AS:-photo}" in
	photo)    method=sendPhoto;    field=photo    ;;
	document) method=sendDocument; field=document ;;
	*)        die "TG_SEND_AS must be photo or document, got: $TG_SEND_AS" ;;
esac

# Retried because throttled networks drop the upload mid-flight rather than refuse it.
response=""
for delay in 0 3 9; do
	[[ "$delay" != 0 ]] && sleep "$delay"
	response="$(
		curl "${curl_opts[@]}" -X POST "${api}/${method}" \
			-F "chat_id=${TG_CHAT_ID}" \
			-F "disable_notification=true" \
			-F "${field}=@${shot};type=image/png;filename=${name}" || true
	)"
	[[ "$response" == *'"ok":true'* ]] && break
done

[[ "$response" == *'"ok":true'* ]] && exit 0

# Do not throw the capture away just because the network did.
spool="$HOME/Pictures/silent-screen-unsent"
mkdir -p "$spool"
mv "$shot" "$spool/$name"
trap - EXIT
die "send failed, kept at $spool/$name — ${response:-no response from ${api%%/bot*}}"
