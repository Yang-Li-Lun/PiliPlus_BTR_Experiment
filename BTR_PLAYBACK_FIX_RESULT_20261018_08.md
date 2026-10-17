# PiliPlus BTR 播放可靠性與高碼率載入候選 08

候選 08 已完成本機修復與離線回歸。Android 實際歷史恢復、首次／連續 Seek、連續音畫、高碼率緩衝及相對最初 BTR 的流暢度仍為 **NOT RUN / UNRESOLVED**；本次未安裝或操作裝置，未連線實際 CDN、未執行長時播放或網路壓測。

## 來源與隔離

- 工作樹：`D:\codee\PiliPlus_BTR_Experiment\.btr-wt\pf-1018-08`。
- 分支：`codex/btr-playback-fix-20261018-08`。
- 基礎：診斷匯出版本 `92c06f6049a37b1495e7cf07f009ed029f098b69`，已核對包含候選 07 `03804e1e619d9a49437cdee7b414a529041aa8e7`。
- 修復程式 commit：`4f9f6e9b759c49a9a5a90cf0455b36aea7effe58`，包含初次修復 `8857997b2ae9dc21306bbe4b0c4ac4b0da551b7b`；本文件以後續文件 commit 保存。
- Build ID：`playback-fix-20261018-08`。
- 最初效能參照 `788faa8abee2ff325205d89a9fa24869821685e3` 保留原位，另實讀其傳輸來源與排程 diff：初版同樣使用 4 個 Handler，但 Seek 會取消舊 demand；08 不恢復這個不安全的取消行為。此次短時對照使用直接前版診斷版本，以辨識這次修改的行為差異；沒有宣稱已恢復初版實機效能。
- 已讀 AGENTS.md、BTR_UPSTREAM.md、tool/btr_upstream.json、BTR_EXPERIMENT.md、07 結果及實際來源。未同步新上游，未修改 main／維護線／穩定分支，未 push、建 PR 或提升版本。
- 所有新增 evidence 在 `evidence/playback-fix-20261018-08/`。Downloads 的兩份使用者 JSON 僅讀取並複製到本候選；原檔未修改。

## 實機資料能證明的範圍

兩份 JSON 的 SHA-256、逐 session 摘要及事件時序保存在 `device-evidence-summary.json`。

- 第二份 JSON：6,242 ms 的 Seek 回報 command-complete；6,245／6,246 ms 的影音新 GET 各遭 handler-capacity 503，當時 activeHandlers=4。generation 0 的影音 GET 到 15,842／15,888 ms 才在 proxy-write timeout 結束。這直接支持本機代理容量與背壓競爭的調查，不能直接歸因到上游 CDN。
- 同一紀錄有 5 次 buffering、14 次 Hedge、12 次 Resume、1 次傳輸失敗、3 次容量拒絕。最後五秒上游 body 約 4.55 Mbps、loopback 成功交付約 1.68 Mbps。這些是不同口徑；包含 probe、重複／過期讀取的接收量不等於播放有效進展。
- `bufferAheadSeconds=2420.606` 同時存在，但 JSON 沒有原始 demuxer cache ranges，不能只靠檔案大小或平均碼率斷言所有快取失真。本機程式則確認直接拿最後快取 timestamp 減目前位置，會把不連續的 EOF 區間算進 buffer；新增測試重現此缺口。
- 第一份 JSON 的一個歷史 session 有 460 個事件被既有有界視窗丟棄；未將不同 session 拼接成同一次故障。部分 native 錯誤只有 ffmpeg／vo 與 unclassified 分類，沒有足以判定原生解碼、AO／音訊路由或 CDN 根因的資料。

## 修復內容

### 歷史位置及 Seek／EOF

`Media.start` 的歷史位置原先未加入 PlaybackSeekIntent 的 pending target。載入期間的 EOF 可因此被當成自然完成，或讓一般 play 進入 native completed 的零秒 replay 分支。

08 在 BTR 歷史載入前保留該目標；open 指令完成後仍須目標附近的實際向前進展才能解除。載入晚完成不能覆蓋期間新下達的 Seek；來源、task close、明確 pause、過期 Seek、原有一次 EOF correction 與有限 reopen 預算都保留。載入期間收到 EOF 時，play 不會在來源操作佇列內等待另一個 open，讓已排入的目標 correction 能在釋放來源所有權後執行。

已觀察到同世代 proxy local failure 的異常 EOF，會使用既有有界 read recovery，不再只等待未分類 native error 或 15 秒 stall。沒有放寬自動重開次數。

`history-controller-red.log` 直接使用未修改診斷版本的 production controller 方法，重現 `history EOF lost saved target`；08 的同一契約案例通過。測試也擷取實際 open 接線、play、Seek、EOF/error callbacks 與鎖定 media_kit log dispatch，驗證歷史載入後的首次及連續 Seek、晚到 open／EOF、pause、來源切換和關閉。這是確定性 native contract stub，沒有執行 Android mpv ABI、解碼或畫面／聲音輸出，不能宣稱已證明實機所有跳轉的單一根因。

### Proxy 背壓與容量

將長回應的所有權與執行槽分開：同時執行仍最多 **4** 個，總共最多 **8** 個已接納回應，包含停等 writer 與排隊需求。這增加了有界的停等容量，沒有把八個回應全部當成可同時執行的 Handler。

flush 等待超過 100 ms 時，writer 暫讓執行槽；有較新 GET 時才回收尚未被消費的 speculative suffix，保留當前 head、最多一塊已驗證連續資料及原回應。單一有效 reader 的短暫背壓保留其預取，不做無競爭的回收。新 GET 可使用讓出的執行槽；舊 writer 在 flush 完成後先計入成功交付，再重新取得執行槽才繼續生產。沒有因為新 GET／Seek 就取消舊 GET，也不重送已寫前綴。

每軌共享 **4 MiB**、上游 **16** 連線、音訊保留容量、原 flush **15 秒** deadline 均保留。重疊時的 head 預留涵蓋有界回應數，單一讀者仍可使用完整視窗。新 admission 最多等待 2 秒；八個回應已滿，或四個執行者都在仍有效的 upstream 工作且未釋出容量時，仍可有可觀測的 503。這是資源界線，並非保證任意數量重疊請求都無拒絕。Android 上的最大回應數、短 Seek burst、OS socket 記憶體與耗電影響仍待確認。

排隊期間發生新 Seek 時，請求保留接收當時的 generation；其晚到失敗不會污染最新 Seek 的恢復判斷。停止／關閉也會取消尚在 admission 的等待者。snapshot 新增 openProxyResponses、parkedProxyWriters、waitingProxyResponses、proxyResponseLimit 等欄位，activeProxyHandlers 現在表示執行槽數。

`capacity-red-02.log` 在未修改診斷版本上重現四個 blocked writer 後新 Range 收到 503。08 同一案例可交付新 Range，且四個舊回應恢復讀取後都與原 payload 逐 byte 相同；取消數為零。完整回歸亦涵蓋真正飽和拒絕、晚到 admission、停止後雙軌重開、無洩漏與所有權上限。

### 高碼率載入相關瓶頸

- BTR 的 buffer 改讀主 demuxer cache state，只計算包含目前播放位置的連續 seekable range，並以 forward cache duration 作上界。缺少、格式異常或無效值保持 null，不沿用舊 EOF timestamp。另輸出 bufferAheadBasis。此資料仍只涵蓋主 demuxer，不冒充影音兩軌的解碼 buffer；原始模式保留既有觀測方式。
- 自動線程仍從 8 開始，保留既有 8／12／16 有用交付試探及退讓。消除虛高 ahead 對試探的抑制，沒有直接把初值改為 16。
- 有持續進展的 head，使用同軌 totalBytes／影片 duration 的平均播放需求判斷 Hedge，避免拿短 probe／瞬間連線速度當必須持續達到的門檻；平均需求未知時只依真正停滯啟動。Resume 前綴不再誤算成當次接收速度。停滯／不足需求的 Hedge 救援、同來源身分、重試及期限仍保留，沒有全面關閉 Hedge。
- 新增 totalBytes 與 estimatedAverageRequiredBps，使後續診斷可以對照交付與平均需求。平均值不是 VBR 峰值或已解碼量，仍須實機實際 buffer／緩衝與連續播放證據。

快取屬性語義另核對 [mpv 官方 property 文件](https://mpv.io/manual/stable/#property-list)：cache-time 是最後快取 timestamp，seekable-ranges 可能不連續，且多 demuxer 時只代表主 demuxer。實際 Android library 是否提供這份節點仍待實機確認；不可取得時輸出 null。

同一短時 loopback 情境交付相同 **1,114,112 bytes**：未修改診斷版接收 **1,900,544 bytes**，有 1 Hedge／1 Resume；08 接收 **1,114,112 bytes**，為 0 Hedge／0 Resume，少掉 786,432 bytes 的重複接收。時間分別 1,091／1,061 ms，各一個受控樣本，不推導實機速度提升比例。資料見 `controlled-delivery-comparison.json`；真正 stalled head 的 Hedge 救援測試仍通過。

CDN 選源、完整 URI 鎖定、strong ETag／If-Range、Range／編碼／長度驗證、redirect 拒絕及 MCDN/P2P 排除未修改；沒有跨 CDN 分塊拼接。原始 PiliPlus bypass、既有播放操作及完整／精簡 JSON 匯出均保留。

## 本機驗證

| 項目 | 結果與證據 |
|---|---|
| 純 Dart／Fake CDN | **136/136 PASS**，`tests-final-04.log`；含 40 個 production controller 子情境，所有 HTTP 僅 loopback |
| 全 app、BTR tests、pubspec 分析 | **0 errors / 0 warnings / 37 infos**，`analyze-app-final-02.log`；37 項均不在修改檔內，`analyze-summary.json` |
| 修改範圍分析 | **No issues found**，`analyze-changed-final-02.log`；涵蓋最後的回收條件與新增回歸案例 |
| 診斷 Flutter channel contract | **10/10 PASS**，`flutter-diagnostics-01.log`；未執行實機 SAF picker |
| 最終 ARM64 DEV APK | **PASS**，158.4 秒，`build-03-final.log`；來源 pin、AOT Build ID、package／ABI／簽章及交付副本 hash 均通過 |
| 完整 app Flutter/native | **BLOCKED，未進入案例**：cnativeapi 缺 Windows MSVC，`flutter-native-01.log` |
| SDK／依賴 | Flutter 3.47.7、Dart 3.13.5；相同 lock／patch 輸入；25 Flutter + 9 material_ui Android reverse checks 通過，未執行 patch helpers，`sdk-patch-android.json` |
| Git | 精確 stage 13 個必要程式／測試檔；diff --check 通過。缺作者設定時僅以單次 git -c 設定 Codex commit 身分，未修改 Git config |
| 保留性 | 其餘 **189 refs、10 個既有 Worktree、790 份檔案**與共享 SDK tracked state 一致，`preservation.json`；舊候選、診斷版本、APK、keys、lock 與歷史 evidence 未覆寫 |
| Android／真實 CDN／初版實機比較 | **NOT RUN / UNRESOLVED** |

原始失敗及探索日誌保留。中途另修正測試等待 response finally 的時序，以及讓視窗測試的 1 MiB piece 不受 loopback timing sample 抖動影響；未放寬 production 上限或錯誤驗證以使測試通過。

最後審查新增「單一 reader 短暫背壓不應丟棄預取」案例，在第一版 08 上重現無競爭回收（sole-pause-red.log），收斂回收條件後通過，相關 14 案亦通過（sole-pause-capacity-green.log）。最終 136 案包含此回歸。初次編譯的中間 APK 保存在 evidence/playback-fix-20261018-08/intermediate-8857997-not-for-delivery.apk，未交付；最後來源重新建置到 build-03-final.log，避免以舊中間 APK 冒充修正後產物。

## APK 建置與後續驗收

初次 build-01 實際出現 `Unable to establish loopback connection`；保留後才用既有 `-ShortIpcPath` 重跑到 build-02-short-ipc.log。IPC 目錄由本候選位置推導為 `.ipc`，只對該建置程序設定 jdk.net.unixdomain.tmpdir；未改 TEMP／TMP、JDK、hosts、Android source 或 dependencies。

APK 原件、交付副本、AOT Build ID、ABI、DEV package、簽章及來源 pin 由 `evidence/playback-fix-20261018-08/verify-artifact.ps1` 核對，結果見同目錄 artifact.json 與 APK 交付目錄 artifact.json。建置來源固定於 build-source.json。

- 交付完整路徑：`D:\codee\PiliPlus_BTR_Experiment\.btr-wt\pf-1018-08\build\btr-candidates\playback-fix-20261018-08\PiliPlus-BTR-PlaybackFix-20261018-08-dev-arm64-v8a.apk`。
- SHA-256：`17a5a4c8f74340d68c44e2dd8bac6c1e5ff270be69c168d481678403f16913fb`。
- 大小：24,525,635 bytes；AOT 實讀 Build ID：`playback-fix-20261018-08`。
- applicationId：`com.example.piliplus.btr.experiment.dev`；label：`PiliPlus BTR DEV`；僅 arm64-v8a；versionName 2.1.6／versionCode 1；minSdk 24／targetSdk 37。
- v2 簽章有效；certificate SHA-256：`fc32b2cbc48673d7f110c98acfcf360bb9a0d5bc166ecfeeeb2bd33935c22264`，與實讀診斷版 APK 相同；permissions 相同，libmpv.so／libflutter.so 雜湊相同。其他非 AOT library 的逐項比較保存在 native-library-comparison.json。
- 六個非 AOT library 與診斷版逐 byte 相同。libdartjni.so 僅 36-byte `.note.gnu.build-id` section 不同；唯讀取出兩份 ELF、在記憶體正規化該 section 後，整份 library SHA-256 相同，`dartjni-comparison.json`。未修改或重新封裝 APK。

後續需由使用者在 Android 實機確認：同裝置／網路／影片／畫質／codec／音軌，從歷史位置開啟後首次與連續 Seek、目標位置的連續音畫、晚到 EOF、自然結尾及結尾往回拖、pause／resume、手動重新載入、原始模式及 JSON 保存。再對照有效交付、停等／排隊回應、bufferAheadBasis 與緩衝事件，判斷高碼率體感是否恢復。無聲、原生大量 unclassified 錯誤與實際 CDN 限流等未證實歸因繼續保留 UNRESOLVED。
