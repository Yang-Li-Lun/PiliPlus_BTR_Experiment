# 本機寫入期限候選：4K 實機短測

## 結果

APK 來源 f33097956ce5d8a45531bdb435e33aaecea91072，Build ID local-write-idle-20261026-01，在指定 POCO M2012K11AG（4138ece6）、DEV 套件 com.example.piliplus.btr.experiment.dev 完成正常播放、三次快速 Seek、一般間隔 Seek 短測。三組均為零容量 503、零 playerErrors、零額外緩衝。這是有條件的 DEV 改善候選，尚未通過整體穩定性驗收，不提升穩定基準 788faa8。

保留 8 回應／4 執行槽／16 上游資源限制、Range／來源驗證／完整性保護。沒有調整 CDN 策略、下載線程或使用者 native 緩衝設定。本輪無原始模式的同時段 A/B，不宣稱相對原始 PiliPlus 的新版效能提升。

## 實際量測

指定影片 BV1kUpsedE4R；選單確認 4K 超高清、HEVC，畫面 1.0X；影音大小 6,507,038,367／45,633,327 bytes，ALI-OV、single-origin-strong-etag。Snapshot 實際 localWriteIdleTimeoutMs=75000。

| 組別 | 恢復時間 ms | 容量 503／playerErrors／額外緩衝 | 記憶體 PSS KiB |
| --- | --- | --- | --- |
| D2 正常播放約 45.6 秒後暫停 | 起播 2,256 | 0／0／0 | 10／25／40 秒：544,413／545,188／590,807 |
| D3 三次快速 Seek | 最後目標 1,733 | 0／0／0 | 前 625,279，後 1,052,064，超過 1 GiB 停止門檻 |
| D4 新程序一般間隔 Seek | 1,160／1,905／914 | 0／0／0 | 前 572,967；三次後 682,346／960,350／986,193 |

D2 由 1,963,297 ms 開始，畫面前進至約 2,005,572 ms。45.6 秒為重載指令返回到暫停指令返回的壁鐘區間，包含起播；原始 session 65,136 ms 包含後續暫停與離開，不是連續播放 65 秒。相較舊診斷 C2（407303f1e，另一鄰近起點）正常播放在 25,722 ms 截斷最新 GET、29,328 ms 出現一次 network player-error，本輪沒有該錯誤：最新 video GET2 在 10,388 與 31,252 ms 先後 parked，中間有 flush 恢復再阻塞，沒有另開 video GET3；直到 source 關閉才取消。不能把 socket 交付當成解碼或第一幀證據，也不是嚴格相同起點 A/B。

D3 目標 809,872／3,099,524／1,912,297 ms，約 1.4 秒間隔。session 29,557／31,002／32,379 ms 發出 Seek；最後一次觸發 seek-capacity。32,686–32,687 ms 八筆 GET 記為 player-stopped，32,688 ms 逐筆釋放至零，然後重開最新目標。快照保存完整 64 筆以內 lifecycle，未丟棄，證明本輪確實到八回應並經回收，不只是沒發生 503。native stop 完成的獨立探針仍未新增；停止前不可回收依 await 程式順序與既有離線 gate 測試，實機 ledger 與之相符。

相對歷史 cold04 4,836 ms，D3 最後恢復時間低約 64.2%；cold04 是修正前診斷候選 f357ef889，不是穩定基準 788faa8 或原始 PiliPlus。兩輪日期、起點、暖機長度與實際手勢間隔不同，不能將速度差獨立歸因於新期限修改。先前容量修正 4a806ca3b 已有 1,500／1,678 ms，故新版不能宣稱比該候選更快。

D4 三次實際目標為 1,948,615／3,099,524／1,912,297 ms，間隔約九秒；第一個目標不同於預定 809,872，不能與歷史三個相同落點逐筆比較。三筆均完成、seekPending=false；最高七回應，不需要 seek-capacity 重開。

## 安全停止、聲畫與釋放

D3 後 PSS 1,052,064／Graphics 650,320 KiB，超過既定 1,048,576 KiB 門檻，未執行下一輪播放；正常關閉後 PSS 730,380／Graphics 330,704。保存全部診斷後僅 force-stop DEV，以新程序 PID 9153 執行 D4，未清除資料。D4 關閉後 PSS 365,787／Graphics 157,644。高圖形記憶體在前版本與無 BTR 原始程序亦有紀錄，但不能據此判斷健康播放下的根因、排除洩漏或確認新版無退化。

D3／D4 末端取樣有單一音軌、48 kHz／2 聲道、opensles／gpu、未靜音，AV sync 分別 -0.000938／-0.000584 秒，取樣掉幀計數零。使用者在 D1 手動交接確認過正常聲畫；本輪沒有逐 Seek 聲學量測、第一幀量測或全程同步驗證。不能將取樣探針當成上述通過。

正常、快速、一般組分別仍有未分類 native log：ffmpeg 2；vo 1／ffmpeg 2；vo 1。與 playerErrors 分開保留。D3 關閉快照有四次、D4 一般快照有兩次、關閉快照有五次 local response timeout；部分是停留在暫停設定畫面時的舊回應，尚未逐 GET 證實消費者無效，不能宣稱本機 response timeout 或任意長暫停續播已解決。

D3／D4 正常離開後 current=null，全部 response／handler／parked／waiting／queued／upstream 及每軌 activeDemands／orderedReservationBytes 均零。D3 關閉快照 lifecycle 丟棄四筆，先前 rapid 快照沒有丟棄，不把兩份快照當成兩輪。這是代理資源釋放證據，不能直接證明 native／GPU 沒有洩漏。

## 操作與證據限制

D2 暫停後進入選單時，未先驗證選單已顯示，後續點擊誤開同 DEV 的另一推薦影片約 27 秒；發現後立即返回，未列入指定影片驗收。匯出 D2-after-navigation.json 的 recent[1] 才是 D2；recent[2] 是誤開影片，current 是恢復原頁的暫停 session，皆不可混算。其餘測試先確認選單節點再操作。本次保留事故截圖與全部原始資料，不刪除或隱藏該事件。

新的工作階段權限為 workspace-write／auto_review。對原先被拒絕的同一條、已授權的 DEV 開片命令提交 require_escalated 正式審查後成功，未使用替代指令繞過。後續可以直接開啟指定影片，不再以舊階段沒有互動核准通道為由要求人工開片。沒有操作 SM-T720、其他 App、清除資料、修改安全設定或長時間播放。

證據在 evidence/local-write-idle-20261026-01/，六份匯出 JSON 均逐一比對手機 SHA-256。verify-device.ps1 是唯讀離線診斷檢查器，核對 Build ID、表示大小、限制、完整 rapid 回收、錯誤與關閉資源；其 PASS 僅限上述條件，不是完整驗收。D2／D3／D4 操作時間另存 actions JSON。

## 建議與剩餘項目

保留 f33097956 作為後續診斷與受限 DEV 使用候選；保留 4a806ca3b APK 回退，不自動提升正式穩定版本。新版正常播放錯誤有改善證據、快速容量回收通過；一般 Seek 功能短測通過。高圖形記憶體、未分類 native log、恢復時間對第一幀的有效性、實際 CDN 故障切換、暫停後續播與完整聲畫同步仍 UNRESOLVED；不以本次局部成功宣稱全部目標完成，也不盲目修改未定位的 native／GPU 問題。

離線完整 suite 156／156 PASS，最終 75 秒防禦上限受影響六項 6／6 PASS；靜態分析 No issues。沿用已核對且條件未變的結果，未重跑。來源、APK／雜湊及簽章詳見 BTR_LOCAL_WRITE_IDLE_CANDIDATE_20261026.md。
