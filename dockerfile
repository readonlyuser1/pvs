# Dockerfile
FROM ubuntu:22.04

LABEL maintainer="readonlyuser1"
LABEL description="PVS Studio Updater with preinstalled dependencies"

ENV DEBIAN_FRONTEND=noninteractive
ENV TZ=UTC

RUN apt-get update && apt-get install -y \
    curl \
    wget \
    jq \
    xmlstarlet \
    bc \
    git \
    ca-certificates \
    && rm -rf /var/lib/apt/lists/* \
    && apt-get clean

WORKDIR /workspace

COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

# Устанавливаем переменную для совместимости с GitHub Actions
ENV GITHUB_OUTPUT=/dev/stdout

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
CMD ["--help"]