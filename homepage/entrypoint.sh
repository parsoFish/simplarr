#!/bin/sh
set -e

# Substitute environment variables into config.json.template and write to nginx serve root
envsubst '${PLEX_PORT} ${OVERSEERR_PORT} ${RADARR_PORT} ${SONARR_PORT} ${PROWLARR_PORT} ${QBITTORRENT_PORT} ${TAUTULLI_PORT}' \
    < /usr/share/nginx/html/config.json.template \
    > /usr/share/nginx/html/config.json

exec nginx -g 'daemon off;'
