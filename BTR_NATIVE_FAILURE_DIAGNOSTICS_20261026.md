# 原生失敗提示與緩衝時間診斷

針對 7c7734d6d 實機 B1 的一次緩衝、A2 新程序原始模式黑畫面與六個錯誤，新增有界固定提示；不是效能修正或已確認根因。

- 原生 log 與 player-error 新增 failureHint，只有固定前綴對應的 enum；符合固定 HTTP 訊息前綴時額外存 reportedHttpStatus 整數。這是原生回報，不代表直接取得已驗證的上游 HTTP response。未知訊息仍標示 unclassified。
- 只檢查訊息前 256 字元，不保存網址、任意尾段、編碼器名稱、路徑、位址或憑證。沿用 128 筆事件上限及 first／last 純量，不新增無界集合。
- DEV 的 BTR_DEVICE_TEST 模式才讓原始模式也訂閱既有 player.stream.log；不建立代理、不探測 CDN、不修改播放器設定。一般非 DEV 原始模式維持原訂閱條件。
- 緩衝狀態變動新增 buffering-transition 時間、seekPending 與 startupComplete；原有計數判定完全不變，不重設、不過濾錯誤或緩衝。

此候選沿用 7c7734d6d 的五行換源順序修正，不含 553114375 續播重開。傳輸／恢復策略、HTTP Range／來源驗證、8／4／16 限制與 15 秒寫入逾時均未改動。

離線完整 suite 首輪 149 PASS／1 FAIL；唯一失敗是新增測試在 seek 清除 previous position 後只送一筆位置，未滿足原有進展契約。修正測試樣本後新診斷五個測試全部 PASS，沒有修改 production 判定來迎合測試。已通過的其餘測試不因測試樣本／格式修正重跑。五修改 Dart 檔靜態分析 No issues found；首次只有新測試 cascade lint，修正後針對性分析通過。

證據在專案 `evidence/source-diag-20261026-02/`。預定 Build ID `source-diag-20261026-02`；本文件建立時尚未建置、安裝或實機取證。仍需使用指定影片、4K HEVC、原始模式的新程序先確認是否能重現重載暖機失敗，再據實際提示決定後續修正；不宣稱 HTTP／TLS／解碼器是已證明的根因。
