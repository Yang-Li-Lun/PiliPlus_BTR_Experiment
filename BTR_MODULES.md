# BTR 模組與上游適配邊界

BTR 維持既有七類職責，不另建 Dart package。實體來源分為 PiliPlus／BTR／integration／tools，所有權與重組流程見 [BTR_SOURCES.md](BTR_SOURCES.md)。表內路徑為可編輯來源，組合後保持原 Flutter 路徑與 import。`BtrExperimentPage` 是共用路由；設定 → 播放設定及播放器更多選單只保留入口，播放畫面 overlay 為唯讀監控。

| 職責 | 實作 | 所有權與契約 |
| --- | --- | --- |
| Transport | `BTR/lib/services/btr/transport.dart`、`network.dart`、`scheduler.dart`、`proxy_capacity.dart`、`local_write_budget.dart` | Range、ETag、排程、Hedge、重試／續傳、loopback 回應及容量；影音各自固定來源與有序視窗，共用上游請求預算 |
| CDN | `BTR/lib/services/btr/policy.dart` | 合格來源、偏好次序、HTTPS、MCDN／P2P 過濾；驗證由 network／transport 執行，禁止跨來源拼接 |
| Playback | `BTR/lib/services/btr/playback.dart`、`read_recovery.dart`、`buffer_ahead.dart` | 每次播放的不可變設定、傳輸 session、播放器事件量測、取消與關閉；共用 task scope 仍使用 `integration/overlay/lib/services/playback_task_scope.dart` |
| Settings | `BTR/lib/services/btr/settings.dart`、`settings_controller.dart`、`ui/settings_panel.dart`；`integration/overlay/lib/services/btr/settings_service.dart` | 模型／遷移、序列化儲存與通知、唯一 Hive binding、完整專屬控制介面；不依賴播放 Session 寫入設定 |
| Diagnostics | `BTR/lib/services/btr/metrics.dart`、`diagnostics.dart`、`diagnostics_export.dart`、`proxy_diagnostics.dart`、`monitor_data.dart`、`surface_probe.dart`、`ui/diagnostics_panel.dart` | 有界記錄與匯出；唯讀顯示沿用 `BTR/lib/pages/setting/widgets/btr_monitor.dart`，不新增探測或播放器輪詢 |
| Android | `BTR/android/app/src/main/kotlin/com/example/piliplus/BtrDiagnosticsExport.kt`、`BtrVerifiedWrite.kt`、`BTR/lib/services/btr/native_property.dart` | 既有 SAF 匯出／覆讀核對、原生屬性介接；MainActivity 保留插件登錄及 AudioService engine 所有權，network security 僅允許 loopback HTTP |
| PiliPlus Adapter | `integration/overlay/lib/services/btr/dash_sources.dart`、`player_integration.dart` | 前者擷取已選定 DASH representation 的原始完整 URL，再呼叫上游 CDN selector；後者為 `PlPlayerController` 的私有 part/extension，接合來源開啟、原生 EDL、Seek、恢復、EOF 與診斷 hook |

## 狀態與生命週期

`PlPlayerController` 持有 player、source sequence、seek intent、task scope、generation、重開預算及目前 BTR session。`player_integration.dart` 共享這些欄位，沒有第二份播放器狀態。原控制器仍負責一般播放 UI、音效、速度、字幕、彈幕及最終 dispose；`setDataSource`、`seek`、`refreshPlayer` 和 stream callbacks 在原有位置呼叫適配方法。

來源替換保留 native stop 完成後才關閉舊 session；容量 Seek／恢復保留 stop → retirePlayerRequests → open。stop 失敗不能先釋放仍有消費者的 GET。來源序號、最新 Seek／pause 意圖、task close 及有界重試檢查仍在原操作順序。`_createVideoController`、Seek 與 refresh 的實作保留在同一 Dart library，轉接方法直接回傳原 Future，沒有額外的 await 邊界。

## 設定契約

- 使用原 Hive setting box 的 `btrExperimentModeV1` 與 `btrSettingsV2`，不更換 key、不清除資料。`threaded`／`switcher` 僅遷移成 `combined`；`original` 保留。原版 CDN、音訊 CDN 及播放器偏好使用自己的既有 key。
- `BtrPreferences.controller` 是唯一 app storage binding。頁面及監控訂閱同一 controller，從持久化 store 讀取設定，不維護額外頁面副本。遷移與儲存依序執行；失敗交回呼叫端，不阻擋後續重試。
- 傳輸 session 在 prepare 時固定設定快照。模式、線程與 CDN 於下一次開啟影片／切換畫質套用；顯示開關在成功儲存後即時通知頁面與 overlay。顯示開關不重設統計或取消傳輸。
- 頁面分為播放模式、多線程傳輸、CDN 來源、監控顯示、即時狀態與診斷。手動值 4／8／16／32／64／128 與 Android 生效上限分列；實際 session 上限、活動請求、來源及事件由監控顯示。原始模式完全繞過 BTR 傳輸。
- 安全上限不是設定：16 個上游請求、8 個 HTTP 回應、4 個執行槽、每軌 4 MiB 有序視窗及既有 timeout／清理限制保持在核心。手動 32／64／128 無法解除它們；實際排程亦可能因自適應或拒絕退讓低於上限。

## 同步新版時的審查入口

依 [BTR_UPSTREAM.md](BTR_UPSTREAM.md) 使用 `tools/btr_sync_upstream.ps1`。預設仍是 `codex/btr-accepted`；明確接續本分離候選使用 `-SourceRef codex/btr-separated-20261106-01`。接受必須另外獲得使用者授權。

16 個官方檔案修改位於 `integration/patches/`，逐檔目標、依賴與審查重點見 [CONTACTS](integration/CONTACTS.md)。官方原件位於 `PiliPlus/`；DASH、播放器私有 part、Hive binding 與共用生命周期 helpers 位於 `integration/overlay/`。分離所有權沒有建立第二個播放器狀態機，也不保證任意上游更新零衝突。

離線驗證使用 `tools/btr.ps1` 的 Core、Settings、Analyze、Native、VerifiedWrite 與 Build；測試原件在 `BTR/test/btr/`。`tools/btr_sources.py verify --baseline` 檢查本次組合結果與模組化來源的 blob 完全相同。設定 UI／channel harness 不等於 Android SAF、實際播放或裝置 UI 驗收。
