# 來源切換時先停止原生消費者

來源為 `565178e3babf180acb903f2d731f9a0296b242e8`，沿用 4a806ca3b 的快速 Seek 容量修正；不包含未通過續播實機 gate 的 553114375 修改。

實際 `_createVideoController` 原先在 native player 尚未 stop 時關閉 previousBtr，之後才 prepare／attach 新 session 並呼叫 player.open。這會先終止舊 GET，且新 session 訂閱可能在原生完成換源前開始收取事件。新候選只在舊 session 有代理時，先 await 原生 stop，再清除舊 owner 並 close；stop 拋錯則保留 owner，不為繼續換源而截斷仍可能有效的 GET。原始模式及第一個來源不增加 stop。

修改只有 controller 的五行 production code，以及新的 source_retirement_test.dart。測試擷取實際 `_createVideoController` 開頭至 prepare 邊界並編譯，模擬 stop barrier、失敗、來源被取代與 task close；驗證停止完成前 owner 不釋放、失敗不關閉、過期來源不 prepare。舊程式四個契約失敗，修改後六個情境全部通過，完整 suite 145／145 PASS。這是離線生命週期契約，不等於 Android 原生輸出已驗收。

保留 8 回應／4 執行槽／16 上游、15 秒寫入逾時、來源驗證、Range、播放器與 CDN 設定；不過濾或重設錯誤與緩衝計數。已確認目前 patched media-kit stop 依序 await stop／playlist-clear／playlist-play-index none，再重設狀態；本候選沿用既有 native stop 所有權邊界。

先前 553114375 實機 R1 在 session 起始 295 ms 內三個錯誤是否由此換源順序造成，仍是待實機比較的假設。本候選不宣稱修復暫停續播的 HTTP body 中斷、高記憶體或未分類原生錯誤；也不把 native stop 的命令完成當第一幀 ready。

證據在專案 `evidence/source-stop-20261026-01/`。預定 Build ID `source-stop-20261026-01`，此文件建立時尚未建置、安裝或實機驗收；後續需確認同影片 4K HEVC 重載、快速／一般 Seek、正常播放沒有退化。穩定基準與既有 APK 保留，不推送、不建立 PR、不正式發布。
