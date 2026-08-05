# Home Assistant + PostgreSQL Docker Compose

[![Home Assistant](https://img.shields.io/badge/Home%20Assistant-2026.x-blue?logo=homeassistant)](https://www.home-assistant.io/)
[![PostgreSQL](https://img.shields.io/badge/PostgreSQL-16-blue?logo=postgresql)](https://www.postgresql.org/)
[![Docker](https://img.shields.io/badge/Docker-Compose-blue?logo=docker)](https://docs.docker.com/compose/)

> 正式環境可用的 Docker Compose / Podman Compose 組合包，以 **PostgreSQL** 取代預設的 SQLite 作為 **Home Assistant** 的記錄器（Recorder）資料庫，提供更好的效能、穩定性與可擴展性。

**本倉庫僅供 Podman / Docker Compose 部署使用。** Kubernetes 部署請參考下方姊妹倉庫。

**[English README](README.md)**

---

## 姊妹倉庫

本專案已依部署平台拆分為獨立倉庫，各平台各自對應一個倉庫：

| 平台 | 倉庫 | 格式 |
|------|------|------|
| **Docker / Podman Compose**（本倉庫） | [Woow_podman_homeassistant](https://github.com/WOOWTECH/Woow_podman_homeassistant) | `docker-compose.yml` |
| **K3s / Kubernetes** | [Woow_k3s_homeassistant](https://github.com/WOOWTECH/Woow_k3s_homeassistant) | Helm chart |

Home Assistant 本身就是智慧家庭作業系統，因此不會有「Home Assistant add-on 版」的本組合包。

---

## 目錄

- [架構](#架構)
- [系統需求](#系統需求)
- [快速開始](#快速開始)
- [專案結構](#專案結構)
- [設定說明](#設定說明)
- [部署操作](#部署操作)
- [日常維護](#日常維護)
- [備份與還原](#備份與還原)
- [常見問題排除](#常見問題排除)
- [參考資料](#參考資料)

---

## 架構

```
┌─────────────────────────────────────────────┐
│              Docker 網路                     │
│              (ha_network)                    │
│                                             │
│  ┌──────────────┐     ┌──────────────────┐  │
│  │  PostgreSQL   │◄────│  Home Assistant   │  │
│  │  (ha_postgres)│     │  (homeassistant)  │  │
│  │  Port: 5432   │     │  Port: 8123       │  │
│  └──────┬───────┘     └────────┬─────────┘  │
│         │                      │             │
│         ▼                      ▼             │
│   postgres_data          ./config            │
│   (Docker volume)    (掛載目錄)              │
└─────────────────────────────────────────────┘
```

| 服務 | 映像檔 | 用途 |
|------|--------|------|
| `homeassistant` | `ghcr.io/home-assistant/home-assistant:stable` | 智慧家庭平台 |
| `postgres` | `postgres:16-alpine` | 記錄器資料庫（取代 SQLite） |

---

## 系統需求

| 項目 | 最低要求 |
|------|---------|
| Docker | 20.10+ |
| Docker Compose | 2.0+（V2 plugin） |
| 記憶體 | 2 GB（建議 4 GB） |
| 硬碟空間 | 10 GB 以上 |
| 作業系統 | Linux / macOS / Windows（WSL2） |

### 安裝 Docker（Ubuntu/Debian）

```bash
# 安裝 Docker
curl -fsSL https://get.docker.com | sh

# 將目前使用者加入 docker 群組（需重新登入）
sudo usermod -aG docker $USER

# 驗證安裝
docker --version
docker compose version
```

---

## 快速開始

### 1. 複製專案

```bash
git clone https://github.com/WOOWTECH/Woow_podman_homeassistant.git
cd Woow_podman_homeassistant
```

### 2. 建立環境變數檔

```bash
cp .env.example .env
```

編輯 `.env`，設定一個**強密碼**：

```bash
nano .env
```

```dotenv
POSTGRES_USER=homeassistant
POSTGRES_PASSWORD=你的安全密碼
POSTGRES_DB=homeassistant
POSTGRES_PORT=5432
HA_VERSION=stable
HA_PORT=8123
TZ=Asia/Taipei
```

### 3. 設定密鑰檔

```bash
cp config/secrets.yaml.example config/secrets.yaml
nano config/secrets.yaml
```

將 `recorder_db_url` 的密碼更新為與 `.env` 一致：

```yaml
recorder_db_url: "postgresql://homeassistant:你的安全密碼@postgres:5432/homeassistant"
```

### 4. 啟動服務

```bash
docker compose up -d
```

### 5. 存取 Home Assistant

在瀏覽器開啟：

```
http://localhost:8123
```

或以伺服器的 IP 位址取代 `localhost`。

### 6. 完成初始設定精靈

首次存取時，Home Assistant 會引導你建立管理員帳號與基本設定。

---

## 專案結構

```
.
├── docker-compose.yml          # Docker Compose 服務定義
├── .env.example                # 環境變數範本
├── .env                        # 你的環境變數（不納入 Git）
├── .gitignore                  # Git 忽略規則
├── README.md                   # 英文文件
├── README_zh-TW.md             # 繁體中文文件
├── DEPLOYMENT.md               # 部署技能參考文件
├── config/
│   ├── configuration.yaml      # Home Assistant 核心設定
│   ├── secrets.yaml.example    # 密鑰範本（納入版控）
│   └── secrets.yaml            # 你的密鑰（不納入 Git）
└── initdb/
    └── 01-init.sql             # PostgreSQL 初始化腳本
```

---

## 設定說明

### 環境變數（`.env`）

| 變數 | 預設值 | 說明 |
|------|--------|------|
| `POSTGRES_USER` | `homeassistant` | PostgreSQL 使用者名稱 |
| `POSTGRES_PASSWORD` | *（必填）* | PostgreSQL 密碼 |
| `POSTGRES_DB` | `homeassistant` | 資料庫名稱 |
| `POSTGRES_PORT` | `5432` | PostgreSQL 對外埠號 |
| `HA_VERSION` | `stable` | Home Assistant 映像檔標籤 |
| `HA_PORT` | `8123` | Home Assistant 對外埠號 |
| `TZ` | `Asia/Taipei` | 時區 |

### Home Assistant 設定（`config/configuration.yaml`）

重點區塊：

- **`recorder`** — 透過 `!secret recorder_db_url` 使用 PostgreSQL；預設保留 30 天資料。
- **`http`** — 已註解反向代理設定，使用 Nginx/Traefik 時取消註解。
- **`logger`** — 預設 warning 等級；recorder 使用 info 等級方便除錯。

### PostgreSQL 初始化腳本（`initdb/01-init.sql`）

首次啟動容器時自動執行：
- 設定資料庫時區為 UTC
- 建立 `ltree` 擴充套件（Home Assistant 記錄器使用）

---

## 部署操作

### 啟動服務

```bash
docker compose up -d
```

### 停止服務

```bash
docker compose down
```

### 停止並刪除所有資料（破壞性操作）

```bash
docker compose down -v
```

### 檢視日誌

```bash
# 所有服務
docker compose logs -f

# 特定服務
docker compose logs -f homeassistant
docker compose logs -f postgres
```

### 更新 Home Assistant

```bash
# 拉取最新映像檔
docker compose pull homeassistant

# 以新映像檔重建容器
docker compose up -d homeassistant
```

### 更新 PostgreSQL

```bash
docker compose pull postgres
docker compose up -d postgres
```

### 檢查服務狀態

```bash
docker compose ps
docker exec ha_postgres pg_isready -U homeassistant
```

---

## 日常維護

### 驗證 PostgreSQL 連線

```bash
docker exec -it ha_postgres psql -U homeassistant -d homeassistant -c "SELECT version();"
```

### 檢查記錄器資料表大小

```bash
docker exec -it ha_postgres psql -U homeassistant -d homeassistant -c "
SELECT
  schemaname || '.' || tablename AS table_name,
  pg_size_pretty(pg_total_relation_size(schemaname || '.' || tablename)) AS size
FROM pg_tables
WHERE schemaname = 'public'
ORDER BY pg_total_relation_size(schemaname || '.' || tablename) DESC
LIMIT 10;
"
```

### 透過 Home Assistant 手動清除

在 Home Assistant 開發者工具 > 服務中呼叫：
- **服務：** `recorder.purge`
- **資料：** `{ "keep_days": 7 }`

---

## 備份與還原

### 備份 PostgreSQL

```bash
# 建立壓縮備份
docker exec ha_postgres pg_dump -U homeassistant -d homeassistant | gzip > backup_$(date +%Y%m%d_%H%M%S).sql.gz
```

### 還原 PostgreSQL

```bash
# 先停止 Home Assistant
docker compose stop homeassistant

# 從備份還原
gunzip -c backup_YYYYMMDD_HHMMSS.sql.gz | docker exec -i ha_postgres psql -U homeassistant -d homeassistant

# 重新啟動 Home Assistant
docker compose start homeassistant
```

### 自動備份（cron）

```bash
# 加入 crontab：每日凌晨 3:00 備份
crontab -e
```

```cron
0 3 * * * docker exec ha_postgres pg_dump -U homeassistant -d homeassistant | gzip > /path/to/backups/ha_db_$(date +\%Y\%m\%d).sql.gz
```

---

## 常見問題排除

### Home Assistant 無法啟動

```bash
# 檢查日誌
docker compose logs homeassistant

# 確認 PostgreSQL 是否正常
docker compose ps
docker exec ha_postgres pg_isready -U homeassistant
```

### 資料庫連線錯誤

1. 確認 `config/secrets.yaml` 中的 `recorder_db_url` 是否正確。
2. 確保 `secrets.yaml` 中的密碼與 `.env` 一致。
3. 確認主機名稱為 `postgres`（Docker 服務名稱），**不是** `localhost`。

### 權限問題

```bash
# 修正 config 目錄擁有者（Linux）
sudo chown -R $USER:$USER config/
```

### 完全重設

```bash
# 移除所有容器、Volume 和網路
docker compose down -v

# 刪除設定（從頭開始）
rm -rf config/.storage config/home-assistant_v2.db

# 重新啟動
docker compose up -d
```

---

## 參考資料

- [Home Assistant 安裝說明（Docker）](https://www.home-assistant.io/installation/linux#docker-compose)
- [Home Assistant Recorder 整合](https://www.home-assistant.io/integrations/recorder/)
- [PostgreSQL Docker Hub](https://hub.docker.com/_/postgres)
- [切換 HA 至 PostgreSQL 指南](https://unixorn.github.io/post/hass-using-postgresql-instead-of-sqlite/)
- [遷移 HA Recorder 至 PostgreSQL](https://newerest.space/home-assistant-recorder-postgresql/)

---

## 授權條款

MIT License。詳見 [LICENSE](LICENSE)。
