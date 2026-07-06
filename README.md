# PVS Studio Updater

Автоматический обновлятор релизов PVS Studio.

## 🐳 Docker Container

Контейнер с предустановленными зависимостями для обновления PVS Studio.

### Использование

```bash
docker pull ghcr.io/readonlyuser1/pvs-updater:latest

docker run --rm \
  -e GITHUB_TOKEN="your_token" \
  -e REPO="readonlyuser1/pvs" \
  ghcr.io/readonlyuser1/pvs-updater:latest