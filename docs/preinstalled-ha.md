# Podman HA 預裝層與來源對齊

## 版本基準

| 來源 | 固定 revision | 在 Podman 的用途 |
|---|---|---|
| [Woow_haos_ha_core](https://github.com/WOOWTECH/Woow_haos_ha_core) | `0db2b04cac91632aa34a22f9610197ee7e22546f` | 官方 HA Core 2026.9.1 基準映像；該 repo 本身沒有整合、主題或設定 seed |
| [ha-rebrand](https://github.com/WOOWTECH/ha-rebrand)（私有） | `5c2e82e6a65c7eafa4958e95b9612c825ea15de9` | 已驗證的共用 seed 與 HA‑MCP 修補來源 |
| [Woow_ha_version_control](https://github.com/WOOWTECH/Woow_ha_version_control)（私有） | `176bfa0fa8359610d3667c85cb778e70f10e5e9f` | 非 add-on 的出貨清單與邊界核對 |
| [Woow_podman_auth_gateway](https://github.com/WOOWTECH/Woow_podman_auth_gateway/releases/tag/2.0.0-r1) | `2.0.0-r1` + SHA‑256 | H618 清單另列的 `woow_protected_apps` 整合 |
| [Mushroom](https://github.com/piitaya/lovelace-mushroom/releases/tag/v5.2.3) | `v5.2.3` + SHA‑256 | H618 清單的 Lovelace Mushroom 卡片資源 |

精確映像 digest 與 revision 記在 [`image/sources.lock.json`](../image/sources.lock.json)。
`ha-rebrand` 的原始全量 Core／前端管線仍以 **2026.7.2** 建置。Podman
`2026.9.1-r7` 沿用官方 2026.9.1 的執行程式與整合，從固定的私有來源
取得品牌語系規則與色票，針對 2026.9.1 的 Core 顯示名稱、PWA manifest、
已編譯前端、前後端翻譯、後端顯示字串與圖示做品牌移植。它不覆蓋舊版 `const.py`，
故 Core 版本與資料庫結構仍是 2026.9.1。第三方供應商名稱、套件識別字
與文件網址保留原樣。

## 預裝內容

`scripts/build-preinstalled.py` 從固定的私有來源產生本機 OCI 映像，公開 Git
倉庫不保存私有原始碼或執行資料。它將下列檔案封裝到映像 `/config`：

| 類別 | 數量 | 來源與行為 |
|---|---:|---|
| Custom components | 22 | `pipelines/shared/armbian-seed` 的 20 個出貨整合，加 Cloud 管線的 `browser_mod` 和 H618 的 `woow_protected_apps`；除 `config_editor` 外預設不建立整合項目 |
| 主題 | 14 | `themes/*.yaml`；新實例的 `frontend.themes` 載入全部主題 |
| 藍圖 | 22 | 18 個 WOOWTECH automation、2 個第三方 automation、2 個 WOOWTECH script；官方內建另有 3 個，因此出貨清單合計 25 個 |
| 靜態資源 | 15 檔 | `www/` 的背景圖、`config-editor-fullpage.js`、Mushroom `mushroom.js`；全新實例在 HA 首次啟動前以獨立 UUID 註冊兩個 JS module |
| 品牌圖示與頁面 | 23 個圖示加 1 個徽章 | 私有 rebrand 的 WoowTech 資源；2026.9.1 前端顯示字串、色票與隨映像提供的語系翻譯另於建置時改寫 |
| Python 依賴 | 依 manifest | Custom component 的 `requirements` 在建置時安裝並通過 `pip check` |
| HA‑MCP 7.14.2 | 獨立 venv | `/opt/woow/ha-mcp`；避免它要求的 `rich`／`websockets` 版本破壞官方 Core 整合 |

HAOS／Supervisor add-on 不在此映像。`woow_protected_apps` 原始碼已預裝，但要有
對應 auth gateway 設定才會啟用保護面板。HA‑MCP 改用
可選的 `homeassistant-mcp.container` 執行，並依 HA 已啟用的整合隱藏
Supervisor、HACS、Assist、radio 等不可用工具。`ha_mcp_tools` 的 UI 僅提供
File/YAML Tools 設定入口；內嵌 server 選項在 Podman 映像中隱藏，以免它把
HA‑MCP 的相衝套件裝入 Core 的 Python 環境。

HA 管理員、HACS GitHub 授權、HA‑MCP token、Matter fabric、設備配對、
Recorder 資料庫及 `.storage` 的機器身分資料都由實際實例建立，不複製進映像。
這符合 version control 的無帳號出貨規格；新實例應由使用者完成 onboarding。

## 建置與安裝

```bash
gh repo clone WOOWTECH/ha-rebrand ~/ha-rebrand
git -C ~/ha-rebrand checkout --detach 5c2e82e6a65c7eafa4958e95b9612c825ea15de9
python3 scripts/build-preinstalled.py --rebrand ~/ha-rebrand
# 映像：localhost/woowtech/ha-preinstalled:2026.9.1-r7
```

建置腳本要求來源 revision 完全符合 lock，另外下載兩個發布檔並檢查 SHA‑256；
也可提供 `--assets-dir` 使用已下載的檔案。它檢查 22 整合／14 主題／22
預裝藍圖、路徑衛生與來源檔案，最後讓兩套 Python 環境各自通過 `pip check`。
`scripts/install.sh` 只在映像帶 `io.woowtech.preinstall=1` 標籤時抽取
`/config`，逐檔寫入主機設定目錄；既有本機 YAML 保留，已由本工具安裝且
未被修改的套件檔案可在升版時更新。若套件檔案被本機修改，整次預裝同步
會停止，並列出衝突檔案。全新設定目錄還會建立無帳號資料的
`.storage/lovelace_resources`，註冊兩個 JS module；既有 `.storage` 一律保留，
需由管理員在「設定 → 儀表板 → 資源」加入缺少的資源。

要啟用 HA‑MCP，先完成 HA onboarding，再將有效的 HA access token 寫成
`homeassistant-mcp-token` Podman secret，然後執行 `scripts/install.sh --with-mcp`。
服務只在本機 `127.0.0.1:9584` 監聽；設定檔不保存 token。需供遠端 MCP
客戶端使用時，另以具身份驗證的代理或通道公開。

## 驗證與限制

- 2026-11-10 `r7` 修正 `cover_rf_time_based` 在 HA 2026.9 註冊
  `set_known_position`／`set_known_action` 時被拒絕的 entity-service schema。
  隔離實例完成開／關、動作與位置 37 的校準；正式服務以 28 MB 冷備份
  從 `r6` 升至 `r7`，23 項 smoke check 全過。HA、MCP、Matter 容器
  healthcheck 皆 healthy；詳細驗證見
  [`custom-components-validation-2026-11-10.md`](custom-components-validation-2026-11-10.md)。
- 2026-11-10 `r6` 修正 `woow_ha_remote_ha_control` 在 HA 重啟後搶先載入代理服務時，
  `service_description_cache` 尚未建立造成 `KeyError` 的問題；快取鍵同步改為
  HA 2026.9 使用的 `(domain, service)`。詳細實測見
  [`custom-components-validation-2026-11-10.md`](custom-components-validation-2026-11-10.md)。
- 2026-11-10 `r5` 加入舊品牌管線的後端顯示字串修補；隔離實例
  `18123` 啟動並回 200，系統資訊的安裝類型已是 `woowtech Container`。
  正式服務以 26 MB 冷備份從 `r4` 切到 `r5`，從另一台區網主機存取
  `8123` 回 200；HA、MCP、Matter 健康檢查全過。授權 API 回報 Core
  `2026.9.1`、161 個已載入元件與 Matter 已載入。升級 smoke 比對為
  22 項通過、0 項關鍵失敗、1 項降級失敗：WLED 取資料時回報
  `invalid_response_github_error`；`r4`／`r5` 的 WLED 程式檔雜湊相同。
  smoke 的 API 項目因未設定獨立測試 header 而跳過，另已用 MCP 所持
  授權在實際 API 驗證。
- 2026-11-10 `r4` 的隔離實例從 HTTP 回傳 `woowtech` PWA 名稱與
  `#6183fc` 主色；繁中應用程式頁面說明符合 Podman 架構，已編譯入口 JS
  與 onboarding HTML 不含原版產品名稱。正式服務以冷備份與自動回滾流程
  從 `r3` 切到 `r4`；切換後 23 項 smoke check 與 29 項部署腳本測試通過。
  HA API 回報 Core `2026.9.1`、161 個已載入元件；從另一台
  `192.168.2.121` 區網主機存取 `192.168.2.46:8123/manifest.json`
  回 200。已登入瀏覽器畫面的品牌驗收仍需在瀏覽器強制重新載入後確認。
- 2026.9.1 `r3` 本機映像在全新隔離設定目錄通過 `homeassistant --script
  check_config`；`/manifest.json`、favicon、Config Editor JS 與 Mushroom JS
  回 200，未登入 `/api/` 回 401；啟動日誌掃到 22 個 custom components。
- 測試帳號完成隔離實例的 onboarding 後，WebSocket 的 `lovelace/resources`
  回報兩個已註冊的 JS module；登入與載入畫面的 WoowTech 標題、圖示也已
  從映像與 HTTP 回應核對。
- HA WebSocket 的 `frontend/get_themes` 回傳 57 個可選名稱，來自 14 個
  預裝主題 YAML；新實例的 `.storage/lovelace_resources` 格式與 API 結果一致。
- 在獨立實例完成測試用 onboarding 後，HA‑MCP HTTP 列出 74 個工具，
  Supervisor 與尚未啟用 HACS 的工具已隱藏；`ha_get_state` 成功讀回
  `sun.sun` 的真實狀態。
- 2026-11-10 在 amd64 rootless Podman／Quadlet 以新設定目錄實際安裝：
  `homeassistant.service`、`homeassistant-mcp.service`、
  `homeassistant-matter.service` 與每日備份 timer 均 active；smoke test
  13 項通過、0 項失敗。Matter 伺服器 5580 回 200，HA 的 Matter
  config entry 狀態為 `loaded`，MCP 因此可列出 74 個工具並成功讀取
  `sun.sun`。另完成線上設定／SQLite 備份，以及停止 HA／Matter 後的
  26 MB 冷備份；冷備份內含 Matter 資料卷，全部 SHA‑256 校驗通過，
  服務重啟後 8123／5580 回 200、Matter entry 與 MCP 工具仍可用；
  三個容器的 Podman healthcheck 均回 `healthy`。提供暫存 API token
  後，正式 smoke test 16 項通過、0 項失敗。
- 實際新實例已建立管理員，但地理位置、analytics 與整合選擇等首次設定
  步驟仍待使用者完成；HACS GitHub 授權、實體 Matter 配對及藍牙硬體
  測試也需要實際帳號或裝置。
- 這台主機有藍牙介面，但 rootless 測試容器沒有管理它的 `NET_ADMIN`／
  `NET_RAW` 權限，因此 HA 自動發現藍牙後會記錄權限錯誤。藍牙硬體能力
  仍須另做有權限的主機驗收；不以網頁 200 視作藍牙通過。
- `2026.9.1-r7` 的品牌層以已編譯的官方前端為基礎，未直接使用
  `ha-rebrand` 2026.7.2 的完整前端程式；更新上游版本時須重新執行
  品牌建置與已登入瀏覽器驗收。瀏覽器可能快取同名 JS 檔，升版後請強制
  重新載入一次。
