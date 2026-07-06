# Dockerfile
FROM ubuntu:22.04

LABEL maintainer="readonlyuser1"
LABEL description="PVS Studio Updater with preinstalled dependencies"

# Устанавливаем переменные окружения
ENV DEBIAN_FRONTEND=noninteractive
ENV TZ=UTC

# Устанавливаем зависимости
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

# Создаем рабочую директорию
WORKDIR /workspace

# Копируем скрипты
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

# Устанавливаем точку входа
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
CMD ["--help"]