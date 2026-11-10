# WOOWTECH HA Core 自製套件實測紀錄（2026-11-10）

## 環境與界線

- 正式服務：`192.168.2.46:8123`，HA Core 2026.9.1；HA-MCP 7.14.2 只監聽本機 `127.0.0.1:9584/mcp`。已在 Codex 註冊 `homeassistant-local`，完成 MCP 初始化、工具清單與 `sun.sun` 狀態讀取。
- 實際已啟用的正式自製整合只有 `config_editor`。預裝 22 個 custom components 並不表示 22 個都在正式服務執行。
- 寫入、重啟與跨節點操作在兩個臨時 HA 容器進行（`18123` 與 `18124`）；各有臨時測試帳號與 MCP。測試帳號、token、容器及資料目錄在測試完成後刪除。
- 正式服務只做不改設定的 MCP 查詢、設定流程開啟後中止、靜態資源 HTTP 核對及升版 smoke test。所有正式設定流程測試前後的 config entry 數量皆為 11。

## 實測結果

| 套件／內容 | 實測結果 | 範圍限制 |
|---|---|---|
| `config_editor` | 正式已載入；隔離實例從 WebSocket 儲存、讀回、列出及刪除測試檔 | 未變更正式設定檔 |
| `ha_mcp_tools`、獨立 HA-MCP | 隔離整合載入 10 個服務；測試 MCP 檔案建立／讀取／列出／刪除，越界路徑遭拒；正式 MCP 72 個工具並可讀取實體 | 檔案工具需同時開啟 beta 與 filesystem 旗標，正式環境保持關閉 |
| `ha_permission_manager` | 隔離實例讀取 1 個使用者、22 個資源；設定、讀回、移除面板權限成功 | 未用非管理員帳號驗證實際阻擋 |
| `woow_ha_records` | finance、asset、health、note 四類資料皆完成建立、讀取、更新、刪除；note 在 HA 重啟後仍存在 | 未做瀏覽器介面驗收 |
| `woow_blueprint_manager` | 列出 20 份 WOOWTECH 藍圖；各由一份 automation 與 script 藍圖建立、列出、刪除實體 | 沒有觸發外部通知 |
| `woow_fan_entity` | 虛擬風扇開／關與連結的 `input_boolean` 狀態同步 | 未接實體風扇 |
| `woow_cover_entity` | 設定位置 42，連結的 `input_number` 同步；外部改為 77，cover 回報 77 | 未接實體捲簾 |
| `template_light_composer` | 虛擬燈開／關與連結的 `input_boolean` 狀態同步 | 未接實體燈 |
| `climate_template` | 隔離實例建立 20°C 測試溫度感測器、設定目標 25°C；切到 heat 時 heater helper 開啟且 `hvac_action=heating`，切回 off 時關閉 | 未接實體空調 |
| `woow_ha_remote_ha_control` | 兩個 HA 節點連線、實體鏡像、遠端 `remote_turn_on`／`remote_turn_off`、重啟後再次代理均通過 | 僅隔離網路中的雙 HA 驗證 |
| `woow_multi_protocol` | 測試 Modbus YAML 儲存／讀取／列出；`apply(force_restart=false)` 回報需重啟而未實際重啟；越界路徑拒絕 | 未接 Modbus／其他實體匯流排；無效路徑目前會在 HA API 回 HTTP 500，未洩露檔案 |
| `woow_zha_quirks` | 隔離設定項目載入，四個服務註冊 | 無 ZHA 實體裝置 |
| `woow_protected_apps` | 隔離載入、面板 JS 回 200、管理員簽發短效 HMAC ticket 並驗章；停用的目標拒絕簽發 | 未啟動目標應用與外部 gateway |
| `scheduler` | 隔離設定項目已載入並跨重啟保存；透過 MCP 建立排程、手動執行動作使 `input_boolean` 開啟，再刪除排程 | 未驗證到點自動觸發 |
| `browser_mod` | 隔離設定項目已載入並跨重啟保存 | 未驗證真實瀏覽器事件 |
| `pyscript` | 隔離實例載入 YAML 設定與測試腳本；經 MCP 呼叫自訂服務，成功開啟 `input_boolean` | 未在正式 HA 安裝任何腳本 |
| `atmocube`、`hacs`、`localtuya`、`nodered`、`woow_tech_somfy_cover` | 正式服務設定流程可開啟並中止，未建立設定項目 | 各自需要供應商授權、外部 Node-RED／裝置，或進一步功能測試 |
| `cover_rf_time_based` | 隔離實例以三個虛擬腳本模擬 RF 訊號；開／關會呼叫對應腳本。`r7` 的 `set_known_position` 與 `set_known_action` 皆註冊並可呼叫；停止後以 `position_type=current` 校準到 37，實體回報位置 37 | 未接 RF 控制器與實體捲簾 |

另外，正式 HA 的 18 個安全 UI 設定流程皆成功開啟並中止；`browser_mod`、`scheduler` 會在流程中自動建立項目，改在隔離實例驗證。22 份預裝藍圖逐份透過 MCP 讀取成功（18 份 WOOWTECH automation、2 份第三方 automation、2 份 WOOWTECH script）；14 個 YAML 主題在 HA 中呈現 57 個選項，隔離實例切換 WOOWTECH 主題後恢復預設。15 個預裝 `www` 靜態檔均經正式 HTTP 請求讀取，SHA-256 與磁碟檔案一致。

## 發現與修正

`r5` 在遠端 HA 節點重啟後，設定項目顯示 `loaded`，但代理服務沒有註冊。日誌指出 `woow_ha_remote_ha_control/proxy_services.py` 讀取尚未建立的 `SERVICE_DESCRIPTION_CACHE` 時發生 `KeyError`。原程式也以字串鍵操作快取，而 HA Core 2026.9.1 使用 `(domain, service)` tuple 鍵。

`r6` 建置器在封裝固定版私有來源時，將快取存取改為惰性建立並使用 tuple 鍵；公開倉庫只保留相容性修補程式，不收錄私有整合原始碼。隔離遠端節點以 `r6` 升版並重啟兩次後，MCP 均可發現代理服務；遠端開／關呼叫使來源與鏡像實體都同步改變，日誌不再有上述 `KeyError`。

進一步的 RF 測試發現 `r6` 的 `cover_rf_time_based` 把 `vol.Schema` 直接傳給 HA 2026.9 的 entity-service 註冊器，導致 `set_known_position`／`set_known_action` 無法註冊。`r7` 建置器改用 HA 的 `cv.make_entity_service_schema`。隔離實例升到 `r7` 後，兩個服務都出現在 MCP 服務清單，位置校準與動作設定均實際通過，日誌不再出現 schema 註冊錯誤。

## 正式服務升版驗收

正式 HA 先從 `r5` 升到 `r6`，再從 `r6` 升到 `r7`；兩次皆先完成約 28 MB 冷備份，升版後各有 23 項 smoke check 通過、0 項失敗。最終 `homeassistant` 與 `homeassistant-mcp` 執行 `2026.9.1-r7`，Matter 容器維持既有版本，三個容器的 Podman healthcheck 都是 `healthy`。`192.168.2.46:8123/manifest.json` 從主機網卡回 HTTP 200。

最終 HA-MCP 重新初始化成功，列出 72 個工具，可讀 `sun.sun`；HA API 回報 Core 2026.9.1，設定項目仍為 11 個，已載入的自製整合仍只有 `config_editor`。正式設定目錄中已確認包含遠端代理快取與 RF entity-service schema 兩項修補。升級備份留在主機 `backups/homeassistant/ha-pre-upgrade-2026.9.1-20261110-183015/backup`。

## 尚未驗證

實體 ZHA、Somfy、RF、LocalTuya、Atmocube、Modbus 與空調裝置；HACS GitHub 授權；Node-RED 外部執行；排程到點自動觸發；保護應用 gateway 的完整跳轉；非管理員權限阻擋；各套件的瀏覽器 UI。這些結果不能從設定流程可開啟或檔案已預裝推論為通過。
