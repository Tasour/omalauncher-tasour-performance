#!/bin/sh
dir="$HOME/.local/share/omalauncher/perf"
pidfile="$dir/logger.pid"
mkdir -p "$dir"
if [ -f "$pidfile" ] && kill -0 "$(cat "$pidfile")" 2>/dev/null; then exit 0; fi
echo $$ > "$pidfile"
trap 'rm -f "$pidfile"' EXIT
trap 'exit 0' INT TERM

cores=$(getconf _NPROCESSORS_ONLN 2>/dev/null || nproc)
filter='^(ps|head|awk|xargs|bash|sh|dash|zsh|fish|proot|libproot.so|foot|tmux: server|pulseaudio|pipewire|wireplumber|dbus-daemon|dbus-broker|dbus-launch|gnome-keyring|gvfsd|xdg-desktop-portal|Xwayland|Xorg|wayland|wlr|labwc|Hyprland|hyprland|sway|swaybg|waybar|mako|dunst|sleep|timeout|tail|grep|sed|date|find|setsid|owl-send|logger.sh|jq|df|systemd|systemd-logind|elogind|openrc|rc-service|login|getty|agetty|ssh|ssh-agent|gpg-agent|init|kworker)$'
prev_ticks=
prev_ts=
n=0

while :; do
  ts=$(date +%s)
  ticks=$(awk -v re="$filter" '{ c=$0; sub(/^[^(]*[(]/, "", c); sub(/[)].*/, "", c); if (c ~ re) next; r=$0; sub(/^[^)]*[)] /, "", r); split(r, f, " "); s += f[12] + f[13] } END { print s+0 }' /proc/[0-9]*/stat 2>/dev/null)
  if [ -n "$prev_ticks" ] && [ -n "$prev_ts" ]; then
    dt=$((ts - prev_ts))
    cpu=$(awk -v t="$ticks" -v pt="$prev_ticks" -v dt="$dt" -v c="$cores" 'BEGIN { if (dt > 0 && c > 0) { v=(t-pt)/(dt*c); if (v<0) v=0; if (v>100) v=100; printf "%.2f", v } else print "null" }')
  else
    dt=null
    cpu=null
  fi
  prev_ticks=$ticks
  prev_ts=$ts

  mem=$(awk '/^MemTotal:/{t=$2}/^MemFree:/{f=$2}/^MemAvailable:/{a=$2}/^Cached:/{c=$2}/^SwapTotal:/{st=$2}/^SwapFree:/{sf=$2} END { printf "{\"total\":%d,\"free\":%d,\"available\":%d,\"cached\":%d,\"swapTotal\":%d,\"swapFree\":%d}", t*1024, f*1024, a*1024, c*1024, st*1024, sf*1024 }' /proc/meminfo)

  storage=$(df -B1 --output=size,used,avail / 2>/dev/null | tail -1 | awk '{ printf "{\"total\":%s,\"used\":%s,\"free\":%s}", $1, $2, $3 }')

  freqs=$(for c in /sys/devices/system/cpu/cpu*/cpufreq; do
    [ -r "$c/scaling_cur_freq" ] || continue
    cur=$(cat "$c/scaling_cur_freq" 2>/dev/null)
    max=$(cat "$c/cpuinfo_max_freq" 2>/dev/null)
    [ -n "$cur" ] && [ -n "$max" ] && printf '%s %s\n' "$cur" "$max"
  done | awk 'BEGIN{printf "["} {if(n++)printf ","; printf "{\"cur\":%s,\"max\":%s}",$1,$2} END{printf "]"}')
  freq_pct=$(printf '%s' "$freqs" | jq 'if length > 0 then (([.[].cur]|add) / ([.[].max]|add) * 100) else null end')

  procs_cpu=$(ps -eo pid=,pcpu=,rss=,comm= --sort=-pcpu | head -40 | awk -v re="$filter" '{ name=$4; for (i=5; i<=NF; i++) name=name " " $i; if (name ~ re) next; if (++c > 5) exit; print $1 "|" $2 "|" $3 "|" name }' | jq -R -s 'split("\n") | map(select(length>0) | split("|") | {pid:(.[0]|tonumber),cpu:(.[1]|tonumber),rss:((.[2]|tonumber)*1024),name:.[3]})')
  procs_ram=$(ps -eo pid=,pcpu=,rss=,comm= --sort=-rss | head -40 | awk -v re="$filter" '{ name=$4; for (i=5; i<=NF; i++) name=name " " $i; if (name ~ re) next; if (++c > 5) exit; print $1 "|" $2 "|" $3 "|" name }' | jq -R -s 'split("\n") | map(select(length>0) | split("|") | {pid:(.[0]|tonumber),cpu:(.[1]|tonumber),rss:((.[2]|tonumber)*1024),name:.[3]})')

  jq -cn --argjson ts "$ts" --argjson dt "$dt" --argjson cores "$cores" --argjson freqPct "$freq_pct" --argjson cpu "$cpu" --argjson mem "$mem" --argjson storage "$storage" --argjson freqs "$freqs" --argjson procsCpu "$procs_cpu" --argjson procsRam "$procs_ram" --arg kernel "$(uname -r)" '{src:"linux", ts:$ts, dt:$dt, kernel:$kernel, freqPct:$freqPct, cores:$cores, cpuPct:$cpu, mem:$mem, storage:$storage, freqs:$freqs, procs:{cpu:$procsCpu, ram:$procsRam}}' >> "$dir/raw-$(date +%F).jsonl"

  n=$((n + 1))
  if [ $((n % 60)) -eq 0 ]; then
    find "$dir" -name 'raw-*.jsonl' -mtime +30 -delete 2>/dev/null
  fi
  sleep 60
done
