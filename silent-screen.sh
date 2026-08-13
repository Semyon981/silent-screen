#!/bin/bash
# silent-screen — capture the screen and push it to a Telegram chat.
#
# Config: ~/.config/silent-screen/config  (chmod 600)
#   TG_BOT_TOKEN=123456:AA...
#   TG_CHAT_ID=987654321
#   TG_PROXY=socks5h://127.0.0.1:1080   # optional, for throttled networks
#   TG_API=https://api.telegram.org     # optional, override for a relay
#
# Usage:
#   silent-screen.sh              full main display
#   silent-screen.sh -i           interactive selection (drag a region)
#   silent-screen.sh -w           click a window to capture it
#   silent-screen.sh --chat-id    print chat ids that messaged the bot

set -euo pipefail

CONFIG="${XDG_CONFIG_HOME:-$HOME/.config}/silent-screen/config"

notify() {
	osascript -e "display notification \"$1\" with title \"silent-screen\"" >/dev/null 2>&1 || true
}

die() {
	printf 'silent-screen: %s\n' "$1" >&2
	notify "$1"
	exit 1
}

[[ -r "$CONFIG" ]] || die "no config at $CONFIG"
# shellcheck source=/dev/null
source "$CONFIG"
: "${TG_BOT_TOKEN:?TG_BOT_TOKEN missing in config}"

api="${TG_API:-https://api.telegram.org}/bot${TG_BOT_TOKEN}"

curl_opts=(-sS --connect-timeout 10 --max-time 60)
[[ -n "${TG_PROXY:-}" ]] && curl_opts+=(--proxy "$TG_PROXY")

if [[ "${1:-}" == "--chat-id" ]]; then
	# Have the user send /start to the bot first, then run this.
	curl "${curl_opts[@]}" "${api}/getUpdates" |
		tr ',' '\n' |
		grep -o '"id":-\{0,1\}[0-9]\{1,\}' |
		sort -u
	exit 0
fi

: "${TG_CHAT_ID:?TG_CHAT_ID missing in config — run --chat-id to find it}"

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

# sendDocument, not sendPhoto: sendPhoto re-encodes to JPEG and smears text.
# Retried because throttled networks drop the upload mid-flight rather than refuse it.
response=""
for delay in 0 3 9; do
	[[ "$delay" != 0 ]] && sleep "$delay"
	response="$(
		curl "${curl_opts[@]}" -X POST "${api}/sendDocument" \
			-F "chat_id=${TG_CHAT_ID}" \
			-F "disable_notification=true" \
			-F "document=@${shot};type=image/png;filename=${name}" || true
	)"
	[[ "$response" == *'"ok":true'* ]] && break
done

if [[ "$response" == *'"ok":true'* ]]; then
	notify "sent"
	exit 0
fi

# Do not throw the capture away just because the network did.
spool="$HOME/Pictures/silent-screen-unsent"
mkdir -p "$spool"
mv "$shot" "$spool/$name"
trap - EXIT
die "send failed, kept at $spool/$name — ${response:-no response from ${api%%/bot*}}"
