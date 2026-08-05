# Home Assistant + PostgreSQL Docker Compose

[![Home Assistant](https://img.shields.io/badge/Home%20Assistant-2026.x-blue?logo=homeassistant)](https://www.home-assistant.io/)
[![PostgreSQL](https://img.shields.io/badge/PostgreSQL-16-blue?logo=postgresql)](https://www.postgresql.org/)
[![Docker](https://img.shields.io/badge/Docker-Compose-blue?logo=docker)](https://docs.docker.com/compose/)

> Production-ready Docker Compose / Podman Compose stack for **Home Assistant** with **PostgreSQL** as the recorder database. Replaces the default SQLite with PostgreSQL for better performance, reliability, and scalability.

**This repository is Podman / Docker Compose only.** For Kubernetes deployments, see the sister repositories listed below.

**[中文版 README](README_zh-TW.md)**

---

## Sister repositories

This project has been split by deployment platform. Each platform is a standalone repository:

| Platform | Repository | Format |
|----------|------------|--------|
| **Docker / Podman Compose** (this repo) | [Woow_podman_homeassistant](https://github.com/WOOWTECH/Woow_podman_homeassistant) | `docker-compose.yml` |
| **K3s / Kubernetes** | [Woow_k3s_homeassistant](https://github.com/WOOWTECH/Woow_k3s_homeassistant) | Helm chart |

Home Assistant is itself the smart-home operating system, so there is no Home Assistant add-on variant of this stack.

---

## Table of Contents

- [Architecture](#architecture)
- [Prerequisites](#prerequisites)
- [Quick Start](#quick-start)
- [Project Structure](#project-structure)
- [Configuration](#configuration)
- [Deployment](#deployment)
- [Maintenance](#maintenance)
- [Backup & Restore](#backup--restore)
- [Troubleshooting](#troubleshooting)
- [References](#references)

---

## Architecture

```
┌─────────────────────────────────────────────┐
│                Docker Network               │
│                (ha_network)                  │
│                                             │
│  ┌──────────────┐     ┌──────────────────┐  │
│  │  PostgreSQL   │◄────│  Home Assistant   │  │
│  │  (ha_postgres)│     │  (homeassistant)  │  │
│  │  Port: 5432   │     │  Port: 8123       │  │
│  └──────┬───────┘     └────────┬─────────┘  │
│         │                      │             │
│         ▼                      ▼             │
│   postgres_data          ./config            │
│   (Docker volume)    (bind mount)            │
└─────────────────────────────────────────────┘
```

| Service | Image | Purpose |
|---------|-------|---------|
| `homeassistant` | `ghcr.io/home-assistant/home-assistant:stable` | Smart-home platform |
| `postgres` | `postgres:16-alpine` | Recorder database (replaces SQLite) |

---

## Prerequisites

| Requirement | Minimum Version |
|------------|----------------|
| Docker | 20.10+ |
| Docker Compose | 2.0+ (V2 plugin) |
| RAM | 2 GB (4 GB recommended) |
| Disk | 10 GB free |
| OS | Linux / macOS / Windows (WSL2) |

### Install Docker (Ubuntu/Debian)

```bash
# Install Docker
curl -fsSL https://get.docker.com | sh

# Add current user to docker group (logout/login required)
sudo usermod -aG docker $USER

# Verify installation
docker --version
docker compose version
```

---

## Quick Start

### 1. Clone the repository

```bash
git clone https://github.com/WOOWTECH/Woow_podman_homeassistant.git
cd Woow_podman_homeassistant
```

### 2. Create your environment file

```bash
cp .env.example .env
```

Edit `.env` and set a **strong password**:

```bash
nano .env
```

```dotenv
POSTGRES_USER=homeassistant
POSTGRES_PASSWORD=YOUR_SECURE_PASSWORD_HERE
POSTGRES_DB=homeassistant
POSTGRES_PORT=5432
HA_VERSION=stable
HA_PORT=8123
TZ=Asia/Taipei
```

### 3. Update the secrets file

```bash
cp config/secrets.yaml.example config/secrets.yaml
nano config/secrets.yaml
```

Update the `recorder_db_url` to match your `.env` password:

```yaml
recorder_db_url: "postgresql://homeassistant:YOUR_SECURE_PASSWORD_HERE@postgres:5432/homeassistant"
```

### 4. Start the stack

```bash
docker compose up -d
```

### 5. Access Home Assistant

Open your browser and navigate to:

```
http://localhost:8123
```

Or replace `localhost` with your server's IP address.

### 6. Complete the onboarding wizard

On your first visit, Home Assistant will guide you through creating your admin account and basic settings.

---

## Project Structure

```
.
├── docker-compose.yml          # Docker Compose services definition
├── .env.example                # Environment variables template
├── .env                        # Your local env (git-ignored)
├── .gitignore                  # Git ignore rules
├── README.md                   # English documentation
├── README_zh-TW.md             # 繁體中文文件
├── DEPLOYMENT.md               # Deployment skill reference
├── config/
│   ├── configuration.yaml      # Home Assistant core config
│   ├── secrets.yaml.example    # Secrets template (tracked)
│   └── secrets.yaml            # Your secrets (git-ignored)
└── initdb/
    └── 01-init.sql             # PostgreSQL initialization script
```

---

## Configuration

### Environment Variables (`.env`)

| Variable | Default | Description |
|----------|---------|-------------|
| `POSTGRES_USER` | `homeassistant` | PostgreSQL username |
| `POSTGRES_PASSWORD` | *(required)* | PostgreSQL password |
| `POSTGRES_DB` | `homeassistant` | Database name |
| `POSTGRES_PORT` | `5432` | PostgreSQL exposed port |
| `HA_VERSION` | `stable` | Home Assistant image tag |
| `HA_PORT` | `8123` | Home Assistant exposed port |
| `TZ` | `Asia/Taipei` | Timezone |

### Home Assistant Config (`config/configuration.yaml`)

Key sections:

- **`recorder`** — Uses PostgreSQL via `!secret recorder_db_url`; purges data older than 30 days.
- **`http`** — Commented-out reverse proxy settings; uncomment if using Nginx/Traefik.
- **`logger`** — Warnings by default; recorder logs at info level for debugging.

### PostgreSQL Init Script (`initdb/01-init.sql`)

Runs once on first container start:
- Sets database timezone to UTC
- Creates the `ltree` extension (used by HA recorder)

---

## Deployment

### Start services

```bash
docker compose up -d
```

### Stop services

```bash
docker compose down
```

### Stop and remove all data (destructive)

```bash
docker compose down -v
```

### View logs

```bash
# All services
docker compose logs -f

# Specific service
docker compose logs -f homeassistant
docker compose logs -f postgres
```

### Update Home Assistant

```bash
# Pull latest image
docker compose pull homeassistant

# Recreate container with new image
docker compose up -d homeassistant
```

### Update PostgreSQL

```bash
docker compose pull postgres
docker compose up -d postgres
```

### Check service health

```bash
docker compose ps
docker exec ha_postgres pg_isready -U homeassistant
```

---

## Maintenance

### Verify PostgreSQL connection

```bash
docker exec -it ha_postgres psql -U homeassistant -d homeassistant -c "SELECT version();"
```

### Check recorder table size

```bash
docker exec -it ha_postgres psql -U homeassistant -d homeassistant -c "
SELECT
  schemaname || '.' || tablename AS table,
  pg_size_pretty(pg_total_relation_size(schemaname || '.' || tablename)) AS size
FROM pg_tables
WHERE schemaname = 'public'
ORDER BY pg_total_relation_size(schemaname || '.' || tablename) DESC
LIMIT 10;
"
```

### Manual purge via Home Assistant

In Home Assistant Developer Tools > Services, call:
- **Service:** `recorder.purge`
- **Data:** `{ "keep_days": 7 }`

---

## Backup & Restore

### Backup PostgreSQL

```bash
# Create a compressed backup
docker exec ha_postgres pg_dump -U homeassistant -d homeassistant | gzip > backup_$(date +%Y%m%d_%H%M%S).sql.gz
```

### Restore PostgreSQL

```bash
# Stop Home Assistant first
docker compose stop homeassistant

# Restore from backup
gunzip -c backup_YYYYMMDD_HHMMSS.sql.gz | docker exec -i ha_postgres psql -U homeassistant -d homeassistant

# Restart Home Assistant
docker compose start homeassistant
```

### Automated backup (cron)

```bash
# Add to crontab: daily backup at 3:00 AM
crontab -e
```

```cron
0 3 * * * docker exec ha_postgres pg_dump -U homeassistant -d homeassistant | gzip > /path/to/backups/ha_db_$(date +\%Y\%m\%d).sql.gz
```

---

## Troubleshooting

### Home Assistant won't start

```bash
# Check logs
docker compose logs homeassistant

# Verify PostgreSQL is healthy
docker compose ps
docker exec ha_postgres pg_isready -U homeassistant
```

### Database connection error

1. Verify `config/secrets.yaml` has the correct `recorder_db_url`.
2. Ensure the password in `secrets.yaml` matches `.env`.
3. Confirm the hostname is `postgres` (the Docker service name), **not** `localhost`.

### Permission issues

```bash
# Fix config directory ownership (Linux)
sudo chown -R $USER:$USER config/
```

### Reset everything

```bash
# Remove all containers, volumes, and networks
docker compose down -v

# Delete config (start fresh)
rm -rf config/.storage config/home-assistant_v2.db

# Start over
docker compose up -d
```

---

## References

- [Home Assistant Installation (Docker)](https://www.home-assistant.io/installation/linux#docker-compose)
- [Home Assistant Recorder Integration](https://www.home-assistant.io/integrations/recorder/)
- [PostgreSQL Docker Hub](https://hub.docker.com/_/postgres)
- [Switch HA to PostgreSQL Guide](https://unixorn.github.io/post/hass-using-postgresql-instead-of-sqlite/)
- [Migrating HA Recorder to PostgreSQL](https://newerest.space/home-assistant-recorder-postgresql/)

---

## License

MIT License. See [LICENSE](LICENSE) for details.

---

## K3s / Kubernetes deployment

K3s/Kubernetes deployment now lives in the dedicated sister repository as a **Helm chart** (Kustomize has been retired):

```bash
helm install homeassistant \
  https://github.com/WOOWTECH/Woow_k3s_homeassistant/archive/refs/heads/main.tar.gz \
  --set secrets.postgresPassword=YOUR_SECURE_PASSWORD_HERE
```

See [Woow_k3s_homeassistant](https://github.com/WOOWTECH/Woow_k3s_homeassistant) for full documentation.

### Deployment methods comparison

| Feature | Podman/Docker Compose (this repo) | K3s/Kubernetes (Woow_k3s_homeassistant) |
|---------|-----------------------------------|-----------------------------------------|
| Orchestrator | Podman / Docker | K3s / Kubernetes |
| Config format | `.env` + `docker-compose.yml` | Helm chart (`values.yaml`) |
| Scaling | Manual | `kubectl scale` |
| Health checks | Docker healthcheck | liveness/readiness/startup probes |
| Service discovery | Docker DNS | Kubernetes DNS (`svc.cluster.local`) |
| Storage | Docker volumes | PersistentVolumeClaims |
| Rolling updates | `docker compose pull && up -d` | `helm upgrade` |
