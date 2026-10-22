# 快速 Seek HTTP 503 容量診斷候選

**Android D1 的實際拒絕分支及舊 GET 消費者狀態仍為 UNRESOLVED。** 本機真實 loopback HTTP 測試已分別重現「8 回應滿額立即拒絕」與「未滿 8 回應、執行槽等待逾時」兩種 503。這證明兩條程式路徑均可發生，不能回推 D1 必然走其中哪條。

本候選只補充有界診斷，未修改取消、排程、容量或回退策略，也未解決快速 Seek 的實機容量拒絕。證據不足以安全認定舊 GET 已無有效消費者，因此停止效能／生命週期策略修改。適合後續另行授權的診斷實機短測，不推薦提升為穩定版。

## 來源與邊界

- Windows 本機專案：`D:\codee\PiliPlus_BTR_Experiment`。
- 穩定基準：`788faa8abee2ff325205d89a9fa24869821685e3`，未變動。
- 前候選工作樹：`.btr-wt/dv-1022-01`；分支 `codex/btr-seek-fairness-20261022-01`；實際 HEAD `08020b4dfeb734689c35f56afd624046ab897355`。相對實作來源 `ed8a5bf4942945ade0990dd3bab95c6e37a0ffe3` 的後續提交為文件，相關 lib/test/tool/android/pubspec 未變動。
- 新候選工作樹：`.btr-wt/cap-1022-01`；分支 `codex/btr-capacity-diagnostics-20261022-01`；由前候選實際 HEAD 隔離建立，沒有改動前候選。
- 本輪只做程式碼、既有證據與離線測試。**未執行 ADB、APK 建置／安裝、實機播放、原生音畫驗收、長測、推送、PR 或正式發布。** 沒有重試或改換指令繞過先前遭 policy 阻擋的操作。
- 主工作樹原有 `AGENTS.md` 修改及 `.codex-remote-attachments/` 未追蹤資料保留，不納入本候選。

## 既有實機證據能確認的範圍

來源為 `evidence/device-playback-20261022-02/D1-burst.json`，SHA-256：`08f49c5be4cf9fb2da68be01ad6f10a0cbc0ebae65c2071a1308bc6a69d699e2`，與原清冊相符。原報告及全部該次證據未修改。

指定影片 `BV1kUpsedE4R`、4K、1.0X 的既有 D1 紀錄：第三次 Seek 在 13,298 ms；Video／Audio 分別於 13,375／13,380 ms 收到本機代理 503，兩者皆記 `handler-capacity`、`activeHandlers=4`。原報告記載兩次 player errors、一次額外緩衝、最後恢復約 5,188 ms；這些是歷史實機結果，本輪沒有新量測改善百分比。

兩個拒絕點之前，均有八筆尚未出現 demand-ended 的 demand-started；但原輸出沒有以下資料：

- 拒絕瞬間的 `_capacity.responses` 與 `_admissions.length`。
- 被拒絕 GET 的 handler 進入時間、實際等待時長與確切分支。
- 各回應的 `response.done` 完成／錯誤時間，以及 `slot.close()` 實際釋放容量時間。
- 舊 GET 的原生播放器消費者是否仍有效。

最早一組 Video／Audio demand 隨後於 15,857／16,165 ms 出現 proxy-write timeout；其餘六筆於 16,728 ms 因 player-stopped 取消，位於既有 16,420 ms seek-read-error reopen 之後。**後來 timeout 或停止，不能證明在拒絕當下已沒有消費者。** demand-ended 也不等於已觀察到 response.done 或 slot 釋放。

逐筆關聯結果保存於 `evidence/capacity-diagnosis-20261022-01/historical-event-audit.json`。未知欄位保留 null／UNOBSERVED，不以事件計數補成實測容量。

## HTTP 拒絕機制與離線觀察

`BtrProxyCapacity.admit()` 在 responses 已達 8 時回傳 null；接納後即增加 response 計數。該計數包含等待執行槽、執行中、因 backpressure 暫讓執行槽及關閉中的 handler，**不是已驗證仍有效的原生消費者數量**。執行槽與 response 容量分開管理；讓出執行槽不釋放 response，只有 handler finally 的 `slot.close()` 會減少 response 計數。

| 路徑 | 實際觸發條件 | 離線拒絕時狀態 | 結果 |
|---|---|---|---|
| response-limit | 有效本機請求、非 retiring、admit() 回傳 null | 8 responses／4 active handlers／4 pending admissions；admission wait 0 ms | 第九筆 GET 收到 503 |
| execution-timeout | 已取得 response 容量，但 acquire 未在既有 2 秒內取得執行槽 | 5 responses／4 active handlers／1 pending admission；實測 2,012 ms | 第五筆 GET 收到 503，自身容量釋放後剩 4 筆 |
| player-stopped | 有效請求到達時 transport 正在 retiring | 本輪未新增此分支的拒絕點專項量測；由實際程式碼確認 | 503，既有 reason 為 player-stopped |
| invalid-request | 本機位址、Host、capability、method 或其他既有檢查不符 | 此機制由實際程式碼及既有回歸覆蓋 | 403，不是本次 handler-capacity 503 |

本機容量拒絕發生在該新 GET 進入 track.serve 前，這兩種離線 503 不是 CDN 回應。其他上游／本機服務例外仍走既有失敗路徑；沒有把所有播放器 HTTP 503 統一歸因本機，也沒有從此推論原始模式黑畫面原因。

實測狀態及 client-close 生命週期見 `offline-observations.json`、`focused-evidence.log`。測試使用 Fake CDN 與真正 Dart HTTP loopback，沒有訪問影片 CDN。測試中已知仍有效的舊讀者，在多次 Seek 後仍完整取得各自指定資料；容量回到 0、取消計數為 0。

## 診斷修改

| 檔案 | 內容 |
|---|---|
| `lib/services/btr/proxy_capacity.dart` | 只新增唯讀 `holdsExecutionSlot` getter。 |
| `lib/services/btr/proxy_diagnostics.dart` | 最多 8 筆當前接納回應、64 筆生命週期、4 個拒絕快照；記錄丟棄數；無 IO、timer、等待或取消。 |
| `lib/services/btr/transport.dart` | 在原拒絕點同步擷取容量、分支、等待時長；在原生命週期節點記錄狀態，於 slot.close 後記錄 released。 |
| `test/btr/proxy_diagnostics_test.dart` | 五項實際 loopback／資料一致性與有界匯出測試。 |
| `BTR_CAPACITY_DIAGNOSIS_20261022.md` | 本報告。 |

拒絕快照包含實際 response／active／parked／pending／upstream 數量及上限、全 transport 唯一 request ID、track、generation，以及每筆已接納回應的階段、已交付 bytes、進度時間、backpressure、執行槽持有狀態、取消原因、server close／deadline、response.done 與容量釋放時間。快照在同一同步呼叫內取得，沒有以 demand 事件數推算 response 數。

新欄位 `capacityCause` 區分原先共用 `handler-capacity` 的兩條路徑；既有 reason、回退判斷和 HTTP status 保留。`response-done` 觀察器不觸發取消。`tokenCancelled=true` 也會出現在正常 finally 清理，須合併 cancellation／outcome 判讀，不可直接當作提前終止。

所有 consumerValidity 明示 `unobservable`。`response.done` 是 Dart 服務端 sink 的完成／錯誤；成功 flush、已交付 bytes、pending done 或 Seek generation 均不能證明原生播放器仍要／不再要該 GET。本機 client 在 24 ms 呼叫 close 的完整套件樣本中，服務端仍於 340 ms 完成 8 MiB 並正常釋放；這個反例不證明 Android 行為或作業系統原因，也不構成安全取消依據。以最新專項輸出中的各自時間為準，不混合不同測試執行的時間軸。

8 response／4 execution／16 upstream、每軌保留上限、既有 deadline、來源／ETag／Range／長度與編碼驗證、有效 GET 的所有權、播放器設定、CDN 策略及執行緒數均未調整。診斷不包含原始 URL、capability、headers、ETag 或原始錯誤文字；釋放後只保留 scalar state，不保留 demand producer callback。完整／精簡 JSON 均保留新 ledger；精簡版可能按既有 soft-budget 規則明示超過 12 KiB。

## 驗證與重現

- BTR 離線套件總共 **144 項均取得通過結果**：完整執行有 143 項通過、1 項因新測試工具缺少 `core_package_config.json` 未能啟動子程序；補齊候選專用路徑設定後，單獨補跑該項通過。它另輸出 40 個控制器契約 PASS。這不是一次零失敗的全套執行。
- 最終五項新測試 **5/5 PASS**：8 回應拒絕點與所有有效 GET byte-exact；5 回應執行等待逾時與自有容量釋放；暫停有效讀者跨 Seek 後恢復完整 8 MiB；client-close 觀察與服務端完成／釋放分離；有界、快照不變性及不洩漏秘密的匯出。
- 既有一般 Seek、重疊 GET、停止／retire、EOF／恢復與媒體完整性回歸包含在上述套件。這些是 Dart／fixture 契約驗證，不是 Android mpv 行為或可聽音訊驗證。
- 四個程式／測試檔靜態分析：**No issues found**；格式與 `git diff --check` 通過。
- 探索期錯誤假設「客戶端要求關閉必然立刻產生 response.done error／不完整 body」未成立；保留原失敗 log。最終測試依實際完成／錯誤狀態驗證記錄一致性，沒有把該反例改稱 Android disconnect 覆蓋。

離線證據目錄：`D:\codee\PiliPlus_BTR_Experiment\evidence\capacity-diagnosis-20261022-01`。主要檔案為 `full-suite.log`、`controller-recovery-rerun.log`、`focused-evidence.log`、`offline-observations.json`、`analyze-delivery.log`、`historical-event-audit.json` 及 `preservation.json`。

重現入口：在專案根目錄執行 `evidence/capacity-diagnosis-20261022-01/run-offline.ps1`；預設五項專項測試，`-TestPath test/btr` 執行完整離線套件，`-Analyze` 分析四個修改檔。工具設定限定新候選；Flutter 3.47.7／Dart 3.13.5 與 pub-cache 以已核對版本、lock、patches 的 junction 重用既有種子，沒有修改種子 SDK、全域 Git 設定或複製簽章金鑰。

## 保留與後續驗收

84 個受保護檔案（原報告、兩個回退／前候選 APK、主 AGENTS 與原指定影片證據）SHA-256 一致；195 個既有 refs 未變動，只新增本診斷分支。保留前候選與穩定基準。新候選僅保留離線重現所需設定及 SDK/cache junction；大型 SDK／APK 沒有重複複製。本輪測試暫存檔逐項檢查，清理新候選自身的可再生 kernel／fixture；既有遭 policy 阻擋的 build 目錄未碰觸。

建議下一步為**另行授權的同條件診斷實機短測**：使用本候選 DEV APK 及獨立 Build ID，在唯一序號確認的 POCO M2012K11AG、限定 DEV package，重現指定影片 4K／1.0X、同三個 Seek 位置與約一秒間距，於拒絕後及回應結束後各匯出完整診斷。建置與裝置操作本輪均未執行。

先確認 rejection 的實際分支、接納回應與釋放時間，再決定是否存在可安全修正的滯留。若需認定 GET 已無消費者，仍須可關聯的原生 HTTP／播放器所有權或明確停止證據；新 ledger 單獨不能補出不可觀察的消費者意圖。不得按舊 generation、低進度或 pending response.done 自動取消。

本輪未提供容量管理修正，也沒有快速 Seek 改善幅度或實機通過結論。推薦保留既有穩定基準；此診斷分支僅供補證據，後續真正策略修正才進入配對快速 Seek A/B 效能驗收。Android 消費者關閉傳播、實際容量滯留原因、原生音畫恢復與診斷額外成本仍待實機確認。
