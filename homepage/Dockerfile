FROM nginx:1.28.2-alpine3.23

RUN apk add --no-cache gettext

COPY index.html /usr/share/nginx/html/index.html
COPY status.html /usr/share/nginx/html/status.html
COPY js/ /usr/share/nginx/html/js/
COPY config.json.template /usr/share/nginx/html/config.json.template
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

ENTRYPOINT ["/entrypoint.sh"]
