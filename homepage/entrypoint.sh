#!/bin/sh
set -e

# Substitute environment variables into config.json.template and write to nginx serve root
# shellcheck disable=SC2016  # reason: single quotes are required by envsubst to prevent bash from expanding variables before envsubst processes them
envsubst '${PLEX_PORT} ${OVERSEERR_PORT} ${RADARR_PORT} ${SONARR_PORT} ${PROWLARR_PORT} ${QBITTORRENT_PORT} ${TAUTULLI_PORT}' \
    < /usr/share/nginx/html/config.json.template \
    > /usr/share/nginx/html/config.json

exec nginx -g 'daemon off;'
