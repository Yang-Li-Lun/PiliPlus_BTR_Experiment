# 有原生緩衝依據的本機寫入期限候選

獨立工作樹 wi-1026-01／分支 codex/btr-local-write-idle-20261026-01，來源 209ba5e83，沿用 407303f1e 的固定診斷與 7c7734d6d 的換源停止邊界；不含未通過的 553114375 續播重開。穩定基準 788faa8 與既有 APK／證據保留。

## 證據與修改

實機 C2 在正常持續播放時，本機最新視訊 response 於 25,722 ms 因 15 秒 flush 逾時套用 deadline=0，之後 29,328 ms 一次 network player-error，原生另開 Range；沒有 Seek、容量拒絕或上游失敗。詳見 BTR_LOCAL_WRITE_DEVICE_BASELINE_20261026.md。

本候選只調整本機 consumer 的 flush 期限：從實際傳給 native 的 cache-secs 與載入時播放速度換算緩衝壁鐘視窗，加上原有 15 秒餘裕，並限制在 15–75 秒。當前 60 秒／1.0X 對應 75 秒；不是提高緩衝大小、下載線程或上游重試期限。未提供原生設定的 core transport 保留預設 15 秒。無效／非有限輸入回到預設，極端有效輸入有硬上限。

timeout 包在可取消的 bind future 外，讓 retire／close 的取消也能立即清除 deadline timer，不留下延長後的 timer 或 response future 引用。停滯 writer 仍在 100 ms 讓出執行槽，回應所有權保留；8 回應／4 執行槽／16 上游限制不變。Source／Range／ETag／完整性、Hedge／Resume、CDN、播放器與錯誤／緩衝計數判定均未改動。只有已確認 native stop 才 retire 舊 GET 的邊界沿用。

Snapshot 新增 localWriteIdleTimeoutMs，供實機核對實際採用值。沒有用 generation、等待時間或寫入停滯認定 GET 消費者失效。

## 離線驗證

- 完整 suite 156／156 PASS；之後將未使用的防禦性上限收緊至目前必要的 75 秒，針對受影響六測試再跑 6／6 PASS，其餘條件未變不重跑。
- 真實 20 秒 pending flush：預設 15 秒分支如期 timeout，配置 75 秒分支仍保有回應且未取消；可 admit 至八筆、拒絕第九筆，drain 完成後容量歸零。
- 短期限的永久 stalled flush 仍有限失敗。子程序持有不會完成的 native-flush future，取消後即釋放全部容量並自行結束，證明沒有留下 75 秒 timer 阻止程序結束。
- 六修改 Dart 檔靜態分析 No issues found；最終上限調整後兩檔針對性分析同樣通過。沒有新增依賴或修改 lock／SDK／patches。

## 實機待驗收與限制

來源 f33097956ce5d8a45531bdb435e33aaecea91072 的 ARM64 DEV APK 已建置並安裝至唯一識別的 POCO M2012K11AG（4138ece6），Build ID local-write-idle-20261026-01。包名 com.example.piliplus.btr.experiment.dev、既有 DEV 簽章與權限均核對一致，安裝保留資料，手機 base.apk 雜湊符合交付檔。

APK：build/btr-candidates/local-write-idle-20261026-01/PiliPlus-BTR-LocalWriteIdle-20261026-01-dev-arm64-v8a.apk。SHA-256：5202f671a9c90e3d72659c24eea5d6e46b3ed7dacb879e6c166e328b0938e866。建置、簽章及安裝證據分別見 evidence/local-write-idle-20261026-01/build.json、apk-verification.json、installed.json。

同影片 4K HEVC／1.0X 的正常播放、三次快速與一般 Seek 短測已完成，三組均零 playerErrors／額外緩衝／容量 503；實際 snapshot timeoutMs=75000。快速最後恢復 1,733 ms，正常關閉後代理資源歸零。完整結果與限制見 BTR_LOCAL_WRITE_DEVICE_RESULT_20261026.md；尚未通過整體穩定性驗收。

後續低供應速率條件下原始／BTR 均有緩衝，切換 Wi-Fi 後正常播放恢復，但快速 Seek 再次超過記憶體停止門檻；另有測試時窗超時與無效原始對照，均保留於 BTR_LOW_SUPPLY_AND_WIFI_RESULT_20261026.md。早先成功短測不能取代這些後續失敗或當作全面穩定性通過。

本候選人工交接已確認正常聲畫。工作階段更新至可正式自動審查後，同一條既有授權的 DEV 開片指令經 require_escalated 審查成功，後續開片限制已解除；未使用其他方式繞過原拒絕。

較久的回應保留可能讓一般 Seek 更早碰到既有八回應邊界；必須量測 stop／retire 的實際成本，不能以零 503 就宣稱改善。有限期限不能被解讀為消費者失效的證據；任意長暫停、載入後變速及其他緩衝設定仍未實機驗收。C1 的過早 Seek 恢復時間軸未在本候選改動，既有一次緩衝仍如實保留，不為取得綠燈調整計數。

證據在專案 evidence/local-write-idle-20261026-01/。若實機不能支持改善，保留最佳已驗證 4a806ca3b 回退，不提升穩定基準、不推送、PR 或正式發布。
