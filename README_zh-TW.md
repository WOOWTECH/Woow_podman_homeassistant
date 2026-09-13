# Woow_podman_homeassistant

以 **Podman Quadlet 單元搭配 systemd** 執行的 Home Assistant Core，全程 rootless，適用於單一
Linux 主機。一道指令完成安裝，一道指令完成升級（失敗自動回滾），現有的手動部署也可以就地接管。

**[English README](README.md)**

- Rootless podman 4.9.3（Ubuntu 24.04 內建版本）、使用者層級 systemd 並啟用 linger，不需要 root daemon
- 使用 host 網路，因此 mDNS/SSDP 探索、HomeKit 橋接與同主機的反向代理都能正常運作
- 預設記錄器是設定目錄裡的 SQLite；PostgreSQL 與 Matter 伺服器為選配
- 映像檔版本釘在本倉庫，本倉庫就是版本的唯一來源
- 主機專屬設定放在 `~/.config/homeassistant/homeassistant.env`（權限 0600），不會進 git

> **原本使用 compose 的人**：本倉庫在 v1 之前是 Docker/Podman Compose 堆疊，最後一版保留在
> [`compose-final`](https://github.com/WOOWTECH/Woow_podman_homeassistant/tree/compose-final) tag。
> 若要使用純 Docker，請依[上游的容器安裝說明](https://www.home-assistant.io/installation/linux#docker-compose)。
> 要把現有容器接管到這裡，請看[遷移既有部署](#遷移既有部署)。

---

## 姊妹倉庫

| 平台 | 倉庫 | 格式 |
|------|------|------|
| **Podman + systemd**（本倉庫） | [Woow_podman_homeassistant](https://github.com/WOOWTECH/Woow_podman_homeassistant) | Quadlet 單元 |
| **K3s / Kubernetes** | [Woow_k3s_homeassistant](https://github.com/WOOWTECH/Woow_k3s_homeassistant) | Helm chart |

Home Assistant 本身就是智慧家庭作業系統，因此沒有對應的 Home Assistant 附加元件版本。

---

## 目錄

- [系統需求](#系統需求)
- [安裝](#安裝)
- [安裝了哪些東西](#安裝了哪些東西)
- [設定項目](#設定項目)
- [日常維運](#日常維運)：[升級](#升級)、[備份](#備份)、[還原](#還原)、[移除](#移除)
- [選配元件](#選配元件)
- [遷移既有部署](#遷移既有部署)
- [安全性](#安全性)
- [反向代理與遠端存取](#反向代理與遠端存取)
- [疑難排解](#疑難排解)
- [測試與 CI](#測試與-ci)

---

## 系統需求

| | |
|---|---|
| 作業系統 | Ubuntu 24.04（或任何 systemd 254 以上的發行版） |
| Podman | 4.9.3 以上，**rootless** |
| systemd | 使用者管理員，且該使用者已啟用 **linger** |
| 磁碟 | 映像檔約 4 GB，另加設定目錄 |
| 連接埠 | 主機的 8123 必須空著（host 網路）；使用 HomeKit / HA-MCP 時還需要 21064 與 9584 |

`scripts/install.sh` 會檢查 podman 版本，必要時替你執行 `loginctl enable-linger` 並啟動
`podman.socket`。所有腳本都**不要**用 `sudo` 執行：整套是 rootless，檔案必須維持屬於你的使用者。

---

## 安裝

```bash
git clone https://github.com/WOOWTECH/Woow_podman_homeassistant.git
cd Woow_podman_homeassistant

# 1. 第一次執行：建立 ~/.config/homeassistant/homeassistant.env 後停下來讓你檢查
scripts/install.sh

# 2. 編輯設定（至少要設定 HA_CONFIG_DIR 與你的 Zigbee 接收器）
${EDITOR:-nano} ~/.config/homeassistant/homeassistant.env

# 3. 正式安裝：算出 unit 內容、dry-run 驗證、拉取映像檔、啟動 HA
scripts/install.sh
```

最後一步會執行 `tests/smoke.sh`，等 Home Assistant 回應後列出檢查結果。接著開啟
`http://<主機>:8123` 完成初始設定精靈。

請保留這份 checkout：`scripts/upgrade.sh`、選配的備份 timer 以及其他腳本都從這裡執行。每次改完
設定檔都要重新執行 `scripts/install.sh`；它是冪等的，只會重啟檔案真的有變動的單元。

常用參數（完整清單見 `scripts/install.sh --help`）：

| 參數 | 作用 |
|---|---|
| `--dry-run` | 只計算、驗證並報告會變動什麼，不動任何東西 |
| `--no-start` | 只安裝檔案並 `daemon-reload` |
| `--no-smoke` | 跳過最後的檢查 |
| `--with-matter` / `--without-matter` | 加入或移除選配的 Matter 伺服器 |
| `--with-postgres` / `--without-postgres` | 加入或移除選配的 PostgreSQL 記錄器 |
| `--with-backup-timer` / `--without-backup-timer` | 加入或移除每日熱備份 timer |

`--with…` / `--without…` 的選擇會存進設定檔，之後直接重跑會沿用。取消選配元件時會停用並移除它的
單元，但**資料一律保留**。

---

## 安裝了哪些東西

| 檔案 | 安裝位置 | 單元 |
|---|---|---|
| `quadlet/homeassistant.container` | `~/.config/containers/systemd/` | `homeassistant.service` |
| `quadlet/optional/homeassistant-matter.container` + `…-matter-data.volume` | 同上 | `homeassistant-matter.service` |
| `quadlet/optional/homeassistant-db.container` + `…-db-data.volume` + `homeassistant.network` | 同上 | `homeassistant-db.service` |
| `systemd/homeassistant-backup.{service,timer}` | `~/.config/systemd/user/` | `homeassistant-backup.timer` |

單元內容是在安裝時算出來的：`@@VAR@@` 佔位符會替換成你的實際值，因此安裝後的 unit 直接就看得出
實際執行的設定。`~/.local/state/woow-quadlet/homeassistant/manifest` 記錄本倉庫安裝了哪些檔案，
移除與備份就是依此判斷哪些東西屬於自己。

Home Assistant 本身：

- `ContainerName=homeassistant`、`Network=host`、`Restart=always`，日誌走 journald
- `Volume=<HA_CONFIG_DIR>:/config:rw`：設定目錄以 bind mount 掛入，檔案仍屬於你
- `--stop-timeout=300`，因為映像檔在關機時會給 HA 240 秒的 s6 緩衝時間
- 對 `127.0.0.1:<HA_PORT>/manifest.json` 做健康檢查；10 分鐘啟動寬限期之後連續 5 次（每 60 秒）
  失敗就會終止容器，再由 systemd 重新啟動
- `ExecStartPre` 最多等待 120 秒讓 DNS 就緒，因為有些自訂元件（例如 HA-MCP）每次啟動都要用
  pip 安裝相依套件，需要名稱解析

日常指令：

```bash
systemctl --user status homeassistant.service
systemctl --user restart homeassistant.service
journalctl --user -u homeassistant.service -f
tests/smoke.sh                 # 健康與一致性檢查，結束碼 0 通過 / 1 嚴重 / 2 降級
```

> Home Assistant 自己的 `homeassistant.stop` 服務現在會讓 HA 又被拉起來，因為單元設定了
> `Restart=always`。要停就用 `systemctl --user stop homeassistant.service`。

---

## 設定項目

`~/.config/homeassistant/homeassistant.env`，一行一個 `KEY=value`：不要加引號、`=` 前後不要空格、
值後面不要接註解。`%h` 代表你的家目錄。

| 設定 | 預設 | 說明 |
|---|---|---|
| `HA_CONFIG_DIR` | `%h/homeassistant/config` | 掛到 `/config` 的設定目錄；指向現有目錄即可接管 |
| `HA_PORT` | `8123` | HA 監聽的連接埠 |
| `HA_PRIVILEGED` | `true` | `--privileged`（與上游一致），或 `false` 搭配 `--group-add=keep-groups` |
| `HA_ZIGBEE_DEVICE` | *(空)* | 接收器的固定 `/dev/serial/by-id/…` 路徑 |
| `HA_ZIGBEE_TARGET` | `/dev/ttyACM0` | HA 在容器內看到的路徑 |
| `HA_EXTRA_DEVICES` | *(空)* | 其他裝置，以空白分隔，格式 `host[:container[:perms]]` |
| `HA_TZ` | `local` | `local` 跟隨主機，填 IANA 名稱則固定，留空為 UTC |
| `HA_BLUETOOTH` | `false` | `true` 會以唯讀掛入 `/run/dbus` 供 BlueZ 使用 |
| `HA_MATTER` | `false` | 選配的 Matter 伺服器 |
| `HA_MATTER_LISTEN_ADDRESS` | `127.0.0.1` | Matter API 沒有任何驗證，請保持只綁本機 |
| `HA_POSTGRES` | `false` | 選配的 PostgreSQL 記錄器 |
| `HA_DB_PORT` | `15432` | 資料庫在本機發布的連接埠 |
| `HA_BACKUP_TIMER` | `false` | 選配的每日熱備份 |
| `HA_BACKUP_DIR` | `%h/backups/homeassistant` | 備份寫入位置 |
| `HA_BACKUP_KEEP` | `5` | `ha-hot-*` / `ha-cold-*` 各保留幾份 |

硬體相關設定請見 [docs/hardware.md](docs/hardware.md)；要設 `HA_PRIVILEGED=false` 或更動 Zigbee
路徑之前請先讀它。

---

## 日常維運

### 升級

版本釘在倉庫裡，所以升級就是取得新的 checkout 再執行腳本：

```bash
git pull                # 或：git checkout v1.1.0
scripts/upgrade.sh
```

它拒絕降版，而且固定依序執行：確認 HA 目前健康 → 先做一份快照供事後比對 → dry-run 新的 unit 並在
**HA 仍在執行時**拉取新映像檔 → 優雅停止 HA → 做一份**冷備份** → 安裝並啟動新版本 → 與快照比對。
嚴重失敗會自動回滾（停止、從冷備份還原設定目錄、重新安裝備份中的 unit 檔案、啟動、再檢查）並以 1
結束。只有降級項目失敗時不會回滾，結束碼為 2。

```bash
scripts/upgrade.sh --rollback        # 手動回到最新的 pre-upgrade 備份
```

舊映像檔會留在磁碟上，因此回滾不需要重新下載。回滾之後，要再跑 `install.sh` 前請先切回對應的舊
版本 tag。

### 備份

```bash
scripts/backup.sh                 # HA 在跑就熱備份，否則冷備份
scripts/backup.sh --hot           # HA 持續執行
scripts/backup.sh --cold --stop   # 停止 HA、完整複製、再啟動
scripts/install.sh --with-backup-timer    # 每天 03:30 熱備份
```

一份備份是 `HA_BACKUP_DIR` 底下權限 `0700` 的目錄，內含 `config.tgz`、`sqlite/*.db.gz`（熱備份：
在容器內以 SQLite 的線上備份 API 複製，並用 `PRAGMA quick_check` 驗證）、已安裝時的 Matter volume
與 Postgres 傾印、已安裝的 unit 檔案、你的設定檔、`manifest.env` 與 `SHA256SUMS`。熱備份與冷備份
各保留最新的 `HA_BACKUP_KEEP` 份；由 `upgrade.sh`、`migrate-legacy.sh` 及 `--dest` 產生的備份永遠
不會被自動刪除。

### 還原

```bash
scripts/restore.sh ~/backups/homeassistant/ha-cold-20260912-0300
scripts/restore.sh <目錄> --with-unit      # 連同備份當時的 HA 版本一起還原
scripts/restore.sh <目錄> --config-only    # 只還原設定目錄，不啟動任何服務
```

它會先驗證 `SHA256SUMS`，停止 HA，在現有設定目錄旁邊解開，最後才互換——原本的設定目錄保留為
`<設定目錄>.pre-restore-<時間戳>`。Home Assistant 無法在新版本已經遷移過的設定上跑舊版本，所以
還原較舊的備份必須加 `--with-unit`（一併回到該版本）或 `--forward`（讓目前版本把它往前遷移，
不可逆）。腳本寧可拒絕也不會亂猜。

### 移除

```bash
scripts/uninstall.sh                  # 停止並移除單元；資料全部保留
scripts/uninstall.sh --dry-run --purge
scripts/uninstall.sh --purge --yes    # 連 volume、網路、secret 與映像檔一起刪除
scripts/uninstall.sh --purge --yes --delete-config=/設定目錄的完整路徑
```

`--purge` 是本倉庫唯一會刪資料的途徑，而且會先把 volume 匯出到
`$HA_BACKUP_DIR/ha-pre-purge-<時間戳>/`；`--delete-config` 必須完全等於設定中的 `HA_CONFIG_DIR`。
設定檔與備份目錄永遠不會被刪除。

---

## 選配元件

| 元件 | 啟用方式 | 文件 |
|---|---|---|
| Matter 伺服器（matter.js 1.4.0） | `scripts/install.sh --with-matter` | [docs/matter.md](docs/matter.md) |
| PostgreSQL 記錄器 | `scripts/install.sh --with-postgres` | [docs/postgres.md](docs/postgres.md) |
| 每日熱備份 | `scripts/install.sh --with-backup-timer` | [備份](#備份) |

兩個選配容器預設都關閉：對大多數安裝來說，設定目錄裡的 SQLite 就是正確選擇，而且 Home Assistant
不會把 SQLite 的歷史資料搬進 PostgreSQL。

---

## 遷移既有部署

若已經存在一個名為 `homeassistant`、而且不是 Quadlet 管理的容器，`scripts/install.sh` 會**拒絕
執行**。這是刻意的：Quadlet 以 `podman run --replace` 啟動 HA，會直接刪掉那個容器連同它的可寫層。

```bash
scripts/migrate-legacy.sh --dry-run     # 只報告，不改任何東西
scripts/migrate-legacy.sh               # 執行遷移，含冷備份與回滾機制
scripts/migrate-legacy.sh --rollback    # 把舊部署放回去
```

腳本會從 `podman inspect` 推導設定（`/config` 掛載、`--privileged`、CreateCommand 裡的裝置、
時區、`/run/dbus`），並在遇到非 host 網路、新 unit 不會帶上的掛載、以及與本 checkout 釘選版本不同
的 HA 版本時拒絕執行；接著做前置快照、優雅停止舊部署、冷備份、停用舊 unit（檔案保留）、把舊容器
改名為 `<名稱>-legacy-<時間戳>`，然後才安裝。安裝後會與快照比對，嚴重檢查失敗時自動回滾。整個過程
記錄在 `$HA_BACKUP_DIR/ha-pre-quadlet-<時間戳>/`。

完整流程（包含比對所需的權杖，以及穩定期後的清理）：[docs/migrating.md](docs/migrating.md)。

---

## 安全性

- **倉庫與 unit 檔案裡沒有任何機密。** PostgreSQL 密碼是由 `install.sh` 以 48 個隨機字元產生的
  podman secret（`homeassistant-db-password`）。`~/.config/homeassistant/homeassistant.env` 以
  0600 建立，而且只放設定、不放機密。
- **Rootless。** 所有容器都以你的使用者在 user namespace 中執行，沒有任何腳本需要 `sudo`。
  Matter 容器另外加上 `NoNewPrivileges=true` 與 `DropCapability=ALL`。
- **預設只綁本機。** 選配資料庫只發布在 `127.0.0.1`；Matter 的 WebSocket API **沒有任何驗證**，
  除非你改 `HA_MATTER_LISTEN_ADDRESS`，否則只綁 `127.0.0.1`。
- **8123 在網路層沒有驗證。** Home Assistant 有自己的登入機制，但不要把它直接對外；請放在
  Cloudflare tunnel 或具備 TLS 的反向代理後面。
- **`HA_PRIVILEGED=true` 只是與上游一致，不是安全邊界。** 它會讓容器看得到主機所有裝置。
  `HA_PRIVILEGED=false` 只傳入你列出的裝置，代價請見 [docs/hardware.md](docs/hardware.md)。
- **備份包含全部內容**，包括帶有 HA 權杖與整合憑證的 `.storage`。備份以 0700/0600 寫入
  `HA_BACKUP_DIR`，請比照設定目錄保護該目錄。
- 若有使用 smoke 測試權杖，它放在 `~/.config/homeassistant/smoke.header`（0600），只有
  `tests/smoke.sh` 會讀取。

---

## 反向代理與遠端存取

Home Assistant 跑在 host 網路上，因此同一台主機上的反向代理或 Cloudflare tunnel 可以用
`localhost:8123` 連到它。但必須讓 Home Assistant 信任它：

```yaml
http:
  use_x_forwarded_for: true
  trusted_proxies:
    - 127.0.0.1
    - ::1
```

用 `tests/smoke.sh --public-url https://ha.example.com` 驗證：`/manifest.json` 必須回 200，
`/api/` 必須回 **401**。回 **400** 就代表 `trusted_proxies` 設錯了。細節與 Nginx Proxy Manager
的做法見 [docs/reverse-proxy.md](docs/reverse-proxy.md)。

---

## 疑難排解

```bash
systemctl --user status homeassistant.service
journalctl --user -u homeassistant.service -n 200 --no-pager
podman healthcheck run homeassistant          # 手動執行健康檢查
podman logs --tail 100 homeassistant
tests/smoke.sh --wait 900                     # 等 HA 起來後列出所有檢查
scripts/install.sh --dry-run                  # 看看會變動什麼，但不真的改
```

| 症狀 | 可能原因 |
|---|---|
| `install.sh` 拒絕：偵測到 legacy 容器 | 存在手動建立的 `homeassistant` 容器 → [先遷移](#遷移既有部署) |
| `install.sh` 拒絕：連接埠被占用 | 有別的程式佔著 8123（host 網路下 HA 無法共用） |
| `install.sh` 拒絕：裝置對應不符 | `HA_PRIVILEGED=true` 時 by-id 連結必須解析成 `HA_ZIGBEE_TARGET`（[docs/hardware.md](docs/hardware.md)） |
| ZHA 打不開接收器 | 舊行程還占著它，或重開機後主機節點編號變了 |
| HA 不斷重啟 | 健康檢查失敗；先看 journal，再跑 `tests/smoke.sh` |
| 重開機後單元沒起來 | linger 沒開：`loginctl enable-linger $USER` |

---

## 測試與 CI

```bash
tests/dryrun.sh          # 算出各種組合的 unit，跑真正的 Quadlet 產生器與 systemd-analyze
tests/scripts-test.sh    # 以 podman/systemctl 替身對 scripts/*.sh 做端對端測試
tests/smoke.sh           # 對執行中的部署做健康與一致性檢查
shellcheck -x scripts/*.sh scripts/lib/*.sh tests/*.sh
```

`tests/dryrun.sh` 與 `tests/scripts-test.sh` 不會建立任何容器，也不會動到你真正的使用者
systemd。GitHub Actions 在 `ubuntu-24.04` 上執行它們（該環境的 podman 就是目標主機的 4.9.3），
同時跑 shellcheck，並檢查 vendored 的 `scripts/lib/quadlet-lib.sh` 未被修改。

---

## 授權條款

MIT，見 [LICENSE](LICENSE)。
