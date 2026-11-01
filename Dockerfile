FROM debian:13-slim

RUN apt-get update \
    && apt-get install -y --no-install-recommends bash iputils-ping mariadb-client \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app
COPY netwatch.sh /app/netwatch.sh
RUN chmod +x /app/netwatch.sh

CMD ["/app/netwatch.sh"]
