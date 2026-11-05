# BTR 模組與上游適配邊界

BTR 使用現有 Dart 模組，不另建 package。傳輸核心維持既有實作及檔名，避免上游合併時混入無關移動。`BtrExperimentPage` 是共用路由；設定 → 播放設定及播放器更多選單只保留入口，播放畫面 overlay 為唯讀監控。

| 職責 | 實作 | 所有權與契約 |
| --- | --- | --- |
| Transport | `lib/services/btr/transport.dart`、`network.dart`、`scheduler.dart`、`proxy_capacity.dart`、`local_write_budget.dart` | Range、ETag、排程、Hedge、重試／續傳、loopback 回應及容量；影音各自固定來源與有序視窗，共用上游請求預算 |
| CDN | `lib/services/btr/policy.dart` | 合格來源、偏好次序、HTTPS、MCDN／P2P 過濾；驗證由 network／transport 執行，禁止跨來源拼接 |
| Playback | `lib/services/btr/playback.dart`、`read_recovery.dart`、`buffer_ahead.dart` | 每次播放的不可變設定、傳輸 session、播放器事件量測、取消與關閉；共用 task scope 仍使用 `lib/services/playback_task_scope.dart` |
| Settings | `lib/services/btr/settings.dart`、`settings_controller.dart`、`settings_service.dart`、`ui/settings_panel.dart` | 模型／遷移、序列化儲存與通知、唯一 Hive binding、完整專屬控制介面；不依賴播放 Session 寫入設定 |
| Diagnostics | `lib/services/btr/metrics.dart`、`diagnostics.dart`、`diagnostics_export.dart`、`proxy_diagnostics.dart`、`monitor_data.dart`、`surface_probe.dart`、`ui/diagnostics_panel.dart` | 有界記錄與匯出；唯讀顯示沿用 `lib/pages/setting/widgets/btr_monitor.dart`，不新增探測或播放器輪詢 |
| Android | `android/app/src/main/kotlin/com/example/piliplus/BtrDiagnosticsExport.kt`、`BtrVerifiedWrite.kt`、`lib/services/btr/native_property.dart` | 既有 SAF 匯出／覆讀核對、原生屬性介接；MainActivity 保留插件登錄及 AudioService engine 所有權，network security 僅允許 loopback HTTP |
| PiliPlus Adapter | `lib/services/btr/dash_sources.dart`、`player_integration.dart` | 前者擷取已選定 DASH representation 的原始完整 URL，再呼叫上游 CDN selector；後者為 `PlPlayerController` 的私有 part/extension，接合來源開啟、原生 EDL、Seek、恢復、EOF 與診斷 hook |

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

依 `BTR_UPSTREAM.md` 使用 `tool/btr_sync_upstream.ps1`。預設來源仍為 `codex/btr-accepted`；本模組化候選未接受前，不會自動成為預設來源。明確接續本候選時使用 `-SourceRef codex/btr-modular-20261106-01`；必須另行獲得接受授權才執行 AcceptCandidate。

三方審查重點：`lib/pages/video/controller.dart` 的 `_dashUrl` 與 NetworkSource 候選、`lib/plugin/pl_player/controller.dart` 的適配呼叫／共享欄位／dispose，以及 `player_integration.dart` 的原生 open/seek 契約。設定入口、overlay、AudioService task removal、MainActivity engine 與 manifest 是其餘已知整合點。此結構減少散落的 BTR 程式，不能保證任意上游更新零衝突。

架構變更先獨立提交，再把該 SHA 當作 `btr_verify_features.ps1 -BtrRef` 的來源。驗證器的 tripwire 追蹤新邊界，但仍要求上游未觸及的 BTR 檔與來源相同；不要把合法架構差異錯列成上游同步的自動例外。

離線驗證：`tool/btr_test.ps1`、`tool/btr_diagnostics_flutter_test.ps1 -IncludeSettings`、Flutter analyze、`tool/btr_sync_tests.ps1`。設定 UI／channel harness 使用正式 Dart 實作及既有 patched Material UI，避開不相關的 Windows native assets；不等同 Android SAF、實際播放或實機 UI 驗收。
