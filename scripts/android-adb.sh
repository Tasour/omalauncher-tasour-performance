#!/bin/sh
# Android perf bridge, read-only, over ADB shell (wireless debugging).
# Writes ~/.cache/omalauncher/android-perf.json for the Performance widget.
# No root required. Pair once: adb pair IP:PORT, then adb connect IP:PORT.
dir="$HOME/.local/share/omalauncher/perf"
outdir="$HOME/.cache/omalauncher"
out="$outdir/android-perf.json"
pidfile="$dir/android-adb.pid"
log="$outdir/android-adb.log"
mkdir -p "$dir" "$outdir"

if [ -f "$pidfile" ] && kill -0 "$(cat "$pidfile")" 2>/dev/null; then exit 0; fi
echo $$ > "$pidfile"

write_unavailable() {
  jq -cn --argjson ts "$(date +%s)" --arg reason "$1" '{ts:$ts,available:false,source:"adb",reason:$reason}' > "$out.tmp" 2>/dev/null && mv "$out.tmp" "$out"
}
cleanup() {
  rm -f "$pidfile"
  write_unavailable "helper arrêté"
}
trap 'if [ -n "$ONESHOT" ]; then rm -f "$pidfile"; else cleanup; fi' EXIT
trap 'exit 0' INT TERM

logmsg() { echo "$(date '+%F %T') $*" >> "$log" 2>/dev/null; }
rotate_log() {
  [ -f "$log" ] || return 0
  lines=$(wc -l < "$log" 2>/dev/null || echo 0)
  [ "$lines" -gt 400 ] 2>/dev/null && tail -n 200 "$log" > "$log.tmp" && mv "$log.tmp" "$log"
}

adb_dev() {
  command -v adb >/dev/null 2>&1 || return 1
  adb devices 2>/dev/null | awk 'NR>1 && $2=="device"{print $1; exit}'
}
mdns_addr() {
  adb mdns services 2>/dev/null | awk '/_adb-tls-connect\._tcp/{print $NF; exit}'
}

while :; do
  rotate_log
  if ! command -v adb >/dev/null 2>&1; then
    write_unavailable "adb absent"
    sleep 30
    [ -n "$ONESHOT" ] && break
    continue
  fi

  dev=$(adb_dev)
  if [ -z "$dev" ]; then
    addr=$(mdns_addr)
    if [ -n "$addr" ]; then
      adb connect "$addr" >/dev/null 2>&1
      sleep 1
      dev=$(adb_dev)
    fi
  fi

  if [ -z "$dev" ]; then
    write_unavailable "aucun appareil adb"
    sleep 15
    [ -n "$ONESHOT" ] && break
    continue
  fi

  model=$(adb -s "$dev" shell getprop ro.product.model 2>/dev/null | tr -d '\r' | head -1)
  android=$(adb -s "$dev" shell getprop ro.build.version.release 2>/dev/null | tr -d '\r' | head -1)
  cpuinfo=$(adb -s "$dev" shell dumpsys cpuinfo 2>/dev/null | tr -d '\r')
  psout=$(adb -s "$dev" shell ps -A -o PID,%CPU,RSS,NAME 2>/dev/null | tr -d '\r')
  thermal=$(adb -s "$dev" shell dumpsys thermalservice 2>/dev/null | tr -d '\r')
  battery=$(adb -s "$dev" shell dumpsys battery 2>/dev/null | tr -d '\r')
  meminfo=$(adb -s "$dev" shell cat /proc/meminfo 2>/dev/null | tr -d '\r')

  cpu_pct=$(printf '%s\n' "$cpuinfo" | awk '
    /^TOTAL:/ {
      u=""; k=""; idle=""
      for (i=1; i<=NF; i++) {
        if ($i ~ /%$/) {
          v=$i; gsub(/%/,"",v)
          if ($(i+1)=="user") u=v
          else if ($(i+1)=="kernel") k=v
          else if ($(i+1)=="idle") idle=v
        }
      }
      if (u=="" && idle!="") u=100-idle-k
      if (u!="") printf "%.1f", u+k
    }' | head -1)

  procs_cpu=$(printf '%s\n' "$cpuinfo" | awk '
    /^[ ]*[0-9.]+% [0-9]+\// {
      pct=$1; gsub(/%/,"",pct)
      tok=$2; sub(/:$/,"",tok)
      pid=tok; sub(/\/.*/,"",pid)
      name=tok; sub(/^[0-9]+\//,"",name)
      if (pid=="" || name=="") next
      printf "%s|%s|%s\n", pid, name, pct
    }' | sort -t'|' -k3 -nr | head -8)

  rss_map=$(printf '%s\n' "$psout" | awk 'NR>1 && $1 ~ /^[0-9]+$/ {printf "%s|%s\n", $1, $3}')

  procs_joined=$(printf '%s\n' "$procs_cpu" | while IFS='|' read -r pid name cpu; do
    [ -z "$pid" ] && continue
    rss=$(printf '%s\n' "$rss_map" | awk -F'|' -v p="$pid" '$1==p{print $2; exit}')
    [ -z "$rss" ] && rss=0
    printf '%s|%s|%s|%s\n' "$pid" "$name" "$cpu" "$rss"
  done)

  procs_json=$(printf '%s\n' "$procs_joined" | jq -R -s '
    split("\n") | map(select(length>0) | split("|") |
    {pid:(.[0]|tonumber), name:.[1], cpu:(.[2]|tonumber), rss:((.[3]|tonumber)*1024)})' 2>/dev/null)
  [ -z "$procs_json" ] && procs_json='[]'

  thermal_json=$(printf '%s\n' "$thermal" | awk '
    /Temperature\{/ {
      line=$0; v=""; n=""
      if (match(line, /mValue=[-0-9.]+/)) v=substr(line,RSTART+7,RLENGTH-7)
      if (match(line, /mName=[^,}]+/)) n=substr(line,RSTART+6,RLENGTH-6)
      if (n!="" && v!="") print n "|" v
    }' | jq -R -s '
    split("\n") | map(select(length>0) | split("|") | {name:.[0], value:(.[1]|tonumber)}) |
    {zones:., max:(map(.value)|max // null),
     cpu:(map(select(.name|test("cpu";"i"))|.value)|max // null),
     gpu:(map(select(.name|test("gpu";"i"))|.value)|max // null),
     battery:(map(select(.name|test("batt";"i"))|.value)|max // null)}' 2>/dev/null)
  [ -z "$thermal_json" ] && thermal_json='null'

  battery_json=$(printf '%s\n' "$battery" | awk '
    /^level:/{l=$2}
    /^temperature:/{t=$2}
    /^health:/{h=$2}
    /^status:/{s=$2}
    /^AC powered:/{ac=$3}
    /^USB powered:/{usb=$3}
    /^Wireless powered:/{w=$3}
    END{
      if(l=="")l="null"; if(h=="")h="null"; if(s=="")s="null"; if(ac=="")ac="null"; if(usb=="")usb="null"; if(w=="")w="null"
      if(t==""){tj="null"}else{tj=sprintf("%.1f",t/10)}
      printf "{\"level\":%s,\"temp\":%s,\"health\":%s,\"status\":%s,\"ac\":%s,\"usb\":%s,\"wireless\":%s}",l,tj,h,s,ac,usb,w
    }' 2>/dev/null)
  [ -z "$battery_json" ] && battery_json='null'

  mem_json=$(printf '%s\n' "$meminfo" | awk '
    /^MemTotal:/{t=$2}
    /^MemAvailable:/{a=$2}
    END{if(t=="")t=0; if(a=="")a=0; printf "{\"total\":%d,\"available\":%d,\"used\":%d}",t*1024,a*1024,(t-a)*1024}' 2>/dev/null)
  [ -z "$mem_json" ] && mem_json='null'

  jq -cn \
    --argjson ts "$(date +%s)" \
    --arg source "adb" \
    --arg model "$model" \
    --arg android "$android" \
    --argjson cpuPct "${cpu_pct:-null}" \
    --argjson procs "$procs_json" \
    --argjson thermal "$thermal_json" \
    --argjson battery "$battery_json" \
    --argjson mem "$mem_json" \
    '{ts:$ts,available:true,source:$source,model:$model,android:$android,cpuPct:$cpuPct,procs:$procs,thermal:$thermal,battery:$battery,mem:$mem}' \
    > "$out.tmp" 2>/dev/null && mv "$out.tmp" "$out"

  logmsg "ok dev=$dev cpu=$cpu_pct procs=$(printf '%s' "$procs_json" | jq 'length' 2>/dev/null)"
  sleep 10
  [ -n "$ONESHOT" ] && break
done
