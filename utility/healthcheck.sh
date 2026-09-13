#!/bin/bash
# End-to-end operational probe for the simplarr Pi. Exit 1 if anything is unhealthy.
# Usage: ./healthcheck.sh [nas-ip]
NAS_IP="${1:-YOUR_NAS_IP}"   # pass the NAS IP as the first argument, or edit this default
fail=0
say() { printf '%-34s %s\n' "$1" "$2"; }
check_http() { # label url expected-regex
  code=$(curl -s -m 8 -o /dev/null -w '%{http_code}' "$2")
  if [[ "$code" =~ $3 ]]; then say "$1" "ok ($code)"; else say "$1" "FAIL ($code)"; fail=1; fi
}
echo "== containers"
while read -r name status; do
  case "$status" in *healthy*|*Up*) say "$name" "$status" ;; *) say "$name" "FAIL: $status"; fail=1 ;; esac
done < <(docker ps -a --format '{{.Names}} {{.Status}}')
echo "== nginx routes"
for p in / /status /health/sonarr /health/radarr /health/prowlarr /health/tautulli /health/overseerr /health/plex /health/qbittorrent; do
  check_http "GET $p" "http://localhost$p" '^(200|302)$'
done
for p in /sonarr /radarr /prowlarr /overseerr /tautulli; do check_http "GET $p" "http://localhost$p" '^(200|301|302|303|307)$'; done
echo "== direct ports"
check_http "sonarr :8989/ping"      http://localhost:8989/ping '^200$'
check_http "radarr :7878/ping"      http://localhost:7878/ping '^200$'
check_http "prowlarr :9696/ping"    http://localhost:9696/ping '^200$'
check_http "tautulli :8181/tautulli/status" http://localhost:8181/tautulli/status '^200$'
check_http "overseerr :5055/status" http://localhost:5055/api/v1/status '^200$'
check_http "qbit ${NAS_IP}:8080"     "http://${NAS_IP}:8080/" '^(200|401|403)$'
code=$(curl -sk -m 8 -o /dev/null -w '%{http_code}' "https://${NAS_IP}:32400/identity"); [ "$code" = 200 ] && say "plex ${NAS_IP}:32400" "ok" || say "plex ${NAS_IP}:32400" "note ($code; needs plex.direct host)"
echo "== mounts (container vs host)"
for spec in sonarr:/tv=/mnt/nas/tv sonarr:/downloads=/mnt/nas/downloads radarr:/movies=/mnt/nas/movies tautulli:/tv=/mnt/nas/tv; do
  c=${spec%%:*}; r=${spec#*:}; cp=${r%%=*}; hp=${r#*=}
  cdev=$(docker exec "$c" stat -c %d "$cp" 2>/dev/null); hdev=$(stat -c %d "$hp" 2>/dev/null)
  if [ -n "$cdev" ] && [ "$cdev" = "$hdev" ]; then say "$c:$cp" "ok"; else say "$c:$cp" "FAIL (container=$cdev host=$hdev)"; fail=1; fi
done
echo "== nginx upstream resolution"
for n in sonarr radarr prowlarr tautulli overseerr homepage; do
  nginx_ip=$(docker exec nginx getent hosts "$n" 2>/dev/null | awk '{print $1}')
  real_ip=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$n" 2>/dev/null)
  if [ -n "$nginx_ip" ] && [ "$nginx_ip" = "$real_ip" ]; then say "$n" "ok ($real_ip)"; else say "$n" "FAIL (nginx sees '$nginx_ip', container is '$real_ip')"; fail=1; fi
done
[ $fail = 0 ] && echo "ALL OK" || echo "PROBLEMS FOUND"
exit $fail
