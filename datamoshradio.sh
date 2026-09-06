#!/bin/bash

API="https://radio.datamosh.ru/api/nowplaying/datamosh_radio"
STREAM="https://radio.datamosh.ru/listen/datamosh_radio/radio.mp3"
MPV_SOCKET="/tmp/datamosh_mpv.sock"
JSON_FILE="/tmp/datamosh_api.json"

G='\033[1;32m'; Y='\033[1;33m'; B='\033[1;34m'; M='\033[1;35m'; W='\033[1;37m'; NC='\033[0m'

playing=true
mpv_pid=""
last_tw=0
last_th=0

last_title=""
display_elapsed=0
poll_counter=0

draw_box() {
    local w=$1 h=$2 x=$3 y=$4
    local hline
    printf -v hline "%*s" $((w-2)) ""
    hline="${hline// /─}"

    tput cup $y $x; printf "┌%s┐" "$hline"
    for ((i=1; i<h-1; i++)); do
        tput cup $((y+i)) $x; printf "│%*s│" $((w-2)) ""
    done
    tput cup $((y+h-1)) $x; printf "└%s┘" "$hline"
}

fmt_time() {
    local t=${1:-0}
    printf "%02d:%02d" $(( t / 60 )) $(( t % 60 ))
}

fetch_api_bg() {
    (
        local tmp="/tmp/datamosh_api_tmp.json"
        if curl -s -H "Cache-Control: no-cache" --max-time 2 "$API?_=$(date +%s)" -o "$tmp"; then
            mv "$tmp" "$JSON_FILE"
        fi
    ) &
}

render() {
    local data=""
    [ -f "$JSON_FILE" ] && data=$(cat "$JSON_FILE")

    local listeners artist title elapsed duration
    {
        read -r listeners
        read -r artist
        read -r title
        read -r elapsed
        read -r duration
    } <<< "$(echo "$data" | jq -r '
        (.listeners.current // 0),
        (.now_playing.song.artist // "???"),
        (.now_playing.song.title // "???"),
        (.now_playing.elapsed // 0),
        (.now_playing.duration // 0)
    ' 2>/dev/null)"

    elapsed=${elapsed:-0}
    duration=${duration:-0}
    listeners=${listeners:-0}
    artist=${artist:-"???"}
    title=${title:-"???"}

    if [[ "$title" != "$last_title" ]]; then
        last_title="$title"
        display_elapsed=$elapsed
    elif $playing; then
        (( display_elapsed++ ))
        local drift=$(( elapsed - display_elapsed ))
        if [ ${drift#-} -gt 3 ]; then
            display_elapsed=$elapsed
        fi
    fi

    if [ -S "$MPV_SOCKET" ]; then
        local safe_title="${title//\"/\\\"}"
        local safe_artist="${artist//\"/\\\"}"
        printf '{"command": ["set_property", "force-media-title", "%s - %s"]}\n' "$safe_artist" "$safe_title" | socat - "$MPV_SOCKET" >/dev/null 2>&1
    fi

    local tw=$(tput cols) th=$(tput lines)
    local w=29 h=10
    local x=$(( (tw - w) / 2 )) y=$(( (th - h) / 2 ))

    if [[ $tw -ne $last_tw || $th -ne $last_th ]]; then
        tput clear
        last_tw=$tw; last_th=$th
        if [ $tw -lt $w ]; then
            echo "Окно маловато!"
            return
        fi
        draw_box $w $h $x $y
    fi

    [ $tw -lt $w ] && return

    local sep_line
    printf -v sep_line "%*s" $((w-4)) ""
    sep_line="${sep_line// /─}"

    tput cup $((y+1)) $((x+2)); printf "${B}datamosh://radio${NC}     "
    tput cup $((y+2)) $((x+2)); printf "%s" "$sep_line"
    
    tput cup $((y+3)) $((x+4)); printf "💿︎  ${Y}%-15s${NC}" "${title:0:$((w-10))}"
    tput cup $((y+4)) $((x+4)); printf "👤︎  ${G}%-15s${NC}" "${artist:0:$((w-10))}"
    
    tput cup $((y+5)) $((x+4))
    $playing && printf "⏸  ${W}Пауза [P]${NC}   " || printf "▶  ${W}Старт [P]${NC}   "

    tput cup $((y+6)) $((x+4))
    printf "⧗  %s / %s      " "$(fmt_time "$display_elapsed")" "$(fmt_time "$duration")"
    
    tput cup $((y+7)) $((x+4))
    printf "🎧︎  Слушают: ${M}%-4s${NC}" "$listeners"
}

cleanup() {
    tput cnorm
    [ -n "$mpv_pid" ] && kill "$mpv_pid" 2>/dev/null
    rm -f "$MPV_SOCKET" "$JSON_FILE" /tmp/datamosh_api_tmp.json
    clear; echo "Bye!"; exit 0
}

trap cleanup INT TERM

rm -f "$MPV_SOCKET" "$JSON_FILE"
tput civis

mpv --no-video \
    --input-ipc-server="$MPV_SOCKET" \
    --demuxer-lavf-o=icy=0 \
    "$STREAM" >/dev/null 2>&1 &
mpv_pid=$!

fetch_api_bg

while true; do
    render

    (( poll_counter++ ))
    if [ $poll_counter -ge 5 ]; then
        fetch_api_bg
        poll_counter=0
    fi

    read -t 1 -n 1 key
    if [[ $key == "p" || $key == "P" ]]; then
        if $playing; then
            kill -STOP "$mpv_pid" && playing=false
        else
            kill -CONT "$mpv_pid" && playing=true
        fi
        render
    fi
done
