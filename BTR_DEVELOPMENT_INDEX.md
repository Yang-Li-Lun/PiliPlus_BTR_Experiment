# PiliPlus BTR 開發資料索引

上游維護架構與尚未接受的新候選：[2026-10-27 維護交付](BTR_MAINTENANCE_RESULT_20261027.md)。下列暫用建議版本與驗收範圍保持原值。

整理日期：2026-10-27。使用者決定「此版本可先使用」，暫用建議固定在 **55fd75e41**；不因後續診斷 APK 或工作樹 HEAD 較新就替換它。這項決定不代表整體穩定性驗收、長時間播放或正式發布通過。

## 暫用建議版本

| 項目 | 固定值 |
| --- | --- |
| 原始碼 commit | `55fd75e41ae518c0330a11ea646ddf8b8b2bcae2` |
| 本機來源標記 | `btr-user-trial-20261027-55fd75e41` |
| Build ID | `http-stop-diag-20261027-01` |
| 套件／ABI | `com.example.piliplus.btr.experiment.dev`／ARM64 |
| APK 大小 | 24,539,943 bytes |
| APK SHA-256 | `7045264a52354ef213332d495a81b84003466c40aedb4817ea48b10a691579cf` |
| DEV 簽章 SHA-256 | `fc32b2cbc48673d7f110c98acfcf360bb9a0d5bc166ecfeeeb2bd33935c22264` |
| 歷史穩定基準 | `788faa8abee2ff325205d89a9fa24869821685e3`（未提升或移動） |

[暫用建議 APK](.btr-wt/sp-1026-01/build/btr-candidates/http-stop-diag-20261027-01/PiliPlus-BTR-HttpStopDiag-20261027-01-dev-arm64-v8a.apk) 是既有封存檔案，不另複製大型 APK。可直接覆蓋更新相同 DEV 套件以保留資料；本次整理沒有操作手機。

機器可讀的 APK 路徑、雜湊、來源與候選狀態：[tool/btr_current_recommendation.json](tool/btr_current_recommendation.json)。`evidence/`、`.btr-wt/`、`build/` 等本機資料不在一般 Git 追蹤內；只有 Git 提交不能恢復 APK 與原始量測，保留這些目錄才保有可重播證據。

## 已驗證範圍與剩餘問題

指定 POCO `M2012K11AG`／序號 `4138ece6`，影片 `BV1kUpsedE4R`，4K／HEVC／1.0X：

| 量測 | 第一輪人工確認 | 第二輪人工確認 |
| --- | --- | --- |
| 三次 Seek 的實際事件間隔 | 897、978 ms | 559、583 ms |
| 最後 Seek 時間軸恢復 | 1876 ms | 2203 ms |
| 503／playerErrors／額外緩衝 | 0／0／0 | 0／0／0 |
| 使用者聲畫觀察 | 恢復，未察覺不同步或錯誤提示 | 恢復，未察覺不同步或錯誤提示 |

時間軸恢復不是每次第一幀或可聽音訊開始時間。資料只支持這兩輪短測，未做長時間播放驗收；保留 8 回應／4 執行槽／16 上游限制、Range／ETag／CDN 身分及完整性保護。已完成且條件未變的離線回歸結果沿用原報告，本次沒有重跑測試或建置 APK。

503 因果對照已直接記到 response-limit 滿八個回應，與執行槽等待逾時區分；原生 stop 完成後才 retire GET，再重開最新目標。控制版與還原修正版最後恢復 5219／1814 ms，但控制版部分早期事件被淘汰，不作正式速度改善百分比。

尚未解決原生 ffmpeg／ImageReader 中斷的精確成因、反覆 Seek 的原生／GPU 資源上界。原始模式同 ALI-OV 的一次對照為 1069 ms、BTR 1960 ms，不能宣稱 BTR 普遍較快。後續影像探針觀測到預覽 handle 已 dispose、閒置後 Graphics 降低，仍不能當成所有原生資源無洩漏的證明。

## 報告與原始證據入口

| 主題 | 報告 | 原始證據目錄（專案根目錄下） |
| --- | --- | --- |
| 55fd 建置、簽章與初次人工短測 | [HTTP 停止診斷](.btr-wt/sp-1026-01/BTR_HTTP_STOP_DIAG_20261027.md) | `evidence/http-stop-diag-20261027-01/` |
| 兩輪較密集 Seek 與人工聲畫確認 | [人工確認](.btr-wt/sp-1026-01/BTR_RAPID_SEEK_HUMAN_CONFIRM_20261027.md) | `evidence/rapid-seek-human-confirm-20261027-01/` |
| 容量退休策略的控制／還原對照 | [容量因果對照](.btr-wt/sp-1026-01/BTR_CAPACITY_ABLATION_RESULT_20261027.md) | `evidence/capacity-ablation-20261027-01/` |
| 原始 PiliPlus／BTR 同主機比較 | [來源對齊比較](.btr-wt/sp-1026-01/BTR_MATCHED_SOURCE_AB_20261027.md) | `evidence/native-source-audit-20261027-01/` |
| 原生 stop／GET 退休與 503 修正 | [容量修正實機結果](.btr-wt/ip-1027-01/BTR_SEEK_CAPACITY_DEVICE_RESULT_20261026.md) | `evidence/seek-capacity-device-20261023-01/`、`evidence/seek-verified-ab-20261026-01/` |
| 原生緩衝對應的有限本機寫入期限 | [期限候選](.btr-wt/ip-1027-01/BTR_LOCAL_WRITE_IDLE_CANDIDATE_20261026.md) | `evidence/local-write-idle-20261026-01/` |
| 縮圖快取候選與記憶體比較 | [預覽記憶體候選](.btr-wt/sp-1026-01/BTR_PREVIEW_MEMORY_CANDIDATE_20261027.md) | `evidence/preview-memory-control-20261027-01/` |
| 有限 HTTP 回應的離線反例 | [有限回應不採用](.btr-wt/rw-1027-01/BTR_RESPONSE_WINDOW_OFFLINE_RESULT_20261027.md) | `evidence/response-window-offline-20261027-01/` |
| image handle 觀測及回退確認 | [影像生命週期探針](.btr-wt/ip-1027-01/BTR_PREVIEW_OWNER_PROBE_RESULT_20261027.md) | `evidence/preview-owner-probe-20261027-01/` |
| 整體驗收缺口與停止決策 | [驗收缺口](.btr-wt/ip-1027-01/BTR_ACCEPTANCE_GAPS_20261027.md) | 上述報告各自引用的原始 JSON／日誌 |

原始量測、失敗樣本、流程偏離及封存清單均保留原路徑，不移動、覆寫或重新封存歷史證據。人工確認目錄的 `manifest.sha256.json` 與探針目錄的 `manifest.json` 是各輪自己的封存清單，不表示所有 evidence 已有相同格式。

## 未採用候選及開發位置

| 來源 | 用途／狀態 | 保留位置 |
| --- | --- | --- |
| `e674fff04a6be6ffe1a4a7aeeb97b9828e4db343` | 有界縮圖快取；局部改善，未取得充分整體驗收證據 | `.btr-wt/sp-1026-01/`，APK 子目錄 `preview-cache-20261027-01` |
| `3e45cb1a0311084c7682c7b3579a51d1ec3beab2` | descriptor 釋放候選；沒有建立額外改善，保留失敗紀錄 | 同工作樹，APK 子目錄 `preview-descriptor-20261027-01` |
| `4d0812b1b3dc18dfd19783ecd7433117c2257b4d` | 有限回應實驗；離線有已確認反例，未建 APK | `.btr-wt/rw-1027-01/` |
| `b195327e45259d34978577c0a3c6102af2566a34` | image ownership 診斷，沒有新的效能修正 | `.btr-wt/ip-1027-01/`，APK 子目錄 `preview-owner-probe-20261027-01` |
| `063da6010f89d7720e854cb1ff539567fe77f10c` | 關閉容量退休策略的實驗控制版，**不可日常使用** | `.btr-wt/sp-1026-01/build/btr-candidates/capacity-ablation-20261027-01/`，檔名包含 `CONTROL-NOT-FOR-USE` |

`sp-1026-01` 的現有分支是預覽快取實驗分支，HEAD `b58cf3347` 含後續實驗與報告；`ip-1027-01` HEAD `247b29d2c` 含探針與驗收文件。它們都不是 55fd 的乾淨建置來源。根目錄 `codex/btr-maintenance` 也不是建議 APK 的來源。未採用候選只是保留研究材料，不自動升級為建議版本。

## 再開發與使用回報

恢復功能開發前，先讀驗收缺口，根據新的可重現症狀或資源所有權證據決定最小修改；沒有新證據時不重跑相同短測、不放寬驗證、不以刪除錯誤訊息代替修復。日常使用若遇異常，可記下影片 BV、畫質／編碼、模式、操作與可見／可聽症狀，並保留當次 DEV 診斷，避免清除資料。

需要重建暫用版時，從固定標記或完整 55fd commit 建立獨立候選，先核對 lock、SDK 與 patches；重用工具鏈前依該來源的 `tool/btr_candidate_setup.ps1` 檢查，不修改種子 SDK。該來源 `tool/btr_build.ps1` 使用 `-DeviceTest -BuildId http-stop-diag-20261027-01`、ARM64 DEV 與既有簽章。重建 APK 可能因建置識別而不同，必須另存並重新驗證，不能覆寫目前封存檔。

所有候選、回退 commit、DEV APK 與 evidence 保留；本次整理沒有封存或刪除工作樹、重寫歷史、變更 AGENTS.md、操作手機或推送遠端。來源標記與本索引屬本機開發交接，不是正式發布。
