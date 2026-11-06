# PiliPlus 整合接點

此目錄只保存必要官方修改及自有適配檔。`sources.json` 是機器可讀的目標／base blob／來源清單；下表路徑相對完整 Flutter 輸出。官方原件位於 `PiliPlus/<path>`，修改位於 `integration/patches/<path>.patch`。

| 官方修改目標 | 保留的依賴與審查重點 |
| --- | --- |
| `lib/plugin/pl_player/controller.dart` | BTR part、共享欄位、原始模式、來源佇列、Seek／恢復／stream hooks、dispose；原生 stop → retire GET → reopen 的順序與失敗保護。 |
| `lib/plugin/pl_player/models/data_source.dart` | NetworkSource 的原始完整影音 URL 候選與不可混軌資料。 |
| `lib/pages/video/controller.dart` | DASH representation 選定後、上游 CDN host 改寫前擷取候選。 |
| `lib/plugin/pl_player/view/view.dart` | 唯讀監控 overlay，保持手勢與關閉後資源清理。 |
| `lib/pages/setting/models/play_settings.dart` | 專屬設定頁入口。 |
| `lib/pages/video/widgets/header_control.dart` | 播放器更多選單的設定／診斷入口。 |
| `lib/services/audio_handler.dart` | Android task removed 關閉所有 PlaybackTaskScope，清除含 isPlaying 的 callbacks；新增通知 customAction 同樣受 task-removed 保護，保留 handler/native 契約。 |
| `lib/pages/audio/controller.dart` | 音訊播放器的 task scope／有序 dispose；上游 open、play、pause、音量初始化的非同步接點保留 task／player owner 檢查。 |
| `lib/common/widgets/image_viewer/gallery_viewer.dart` | Live Photo 播放器的 acquisition/dispose 與 task close，避免背景殘留。 |
| `android/app/src/main/kotlin/com/example/piliplus/MainActivity.kt` | AudioService engine 所有權、診斷匯出 channel 與原有 plugin 登錄。 |
| `android/app/src/main/AndroidManifest.xml` | BTR network security 與原生生命周期相關設定。 |
| `android/app/build.gradle.kts` | BTR applicationId、DEV suffix/label、既有 DEV signing key 位置。 |
| `android/app/src/main/res/values/string.xml` | BTR app 顯示名稱。 |
| `android/app/src/main/res/xml-v25/shortcuts.xml` | BTR package 對應 shortcut。 |
| `pubspec.yaml`、`pubspec.lock` | 在官方 pin 的依賴版本上，僅補既有 BTR test_api／matcher 直接測試依賴宣告；其版本不變。 |

`overlay/lib/services/btr/player_integration.dart` 保持原 private part；`dash_sources.dart` 為 DASH selector adapter；`settings_service.dart` 為唯一 Hive app binding。`overlay/lib/services/` 的四個 lifecycle／source／seek helpers 由播放器、音訊與 Live Photo 共用，必須跟上述 patch 一起審查。`overlay/android/.../btr_network_security.xml` 僅允許既有 loopback HTTP。

不能將 adapter 改成另一套播放器狀態機，不能改 Hive keys 或清除資料，不能放寬 Range/ETag、來源驗證、HTTPS、MCDN/P2P 過濾、禁止跨 CDN 拼接、容量或原生生命周期限制。patch base 不符時，先比較舊官方／新官方／現有整合，不可直接更新 baseBlob 繞過審查。
