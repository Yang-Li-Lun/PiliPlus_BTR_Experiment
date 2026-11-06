# PiliPlus BTR 分離來源候選

本工作樹以 `PiliPlus/`、`BTR/`、`integration/`、`tools/` 分離官方來源、自有功能、整合接點與工具。這是本機未接受候選；穩定使用版仍由 `codex/btr-stable` 與 [版本清單](tools/legacy/btr_current_recommendation.json) 定義。

- [來源所有權與重組方式](BTR_SOURCES.md)
- [BTR 模組與不變契約](BTR_MODULES.md)
- [上游同步與接受規則](BTR_UPSTREAM.md)
- [整合接點清單](integration/CONTACTS.md)
- [官方 PiliPlus README](PiliPlus/README.md)
- [開發及驗收索引](BTR_DEVELOPMENT_INDEX.md)

在本工作樹根目錄使用 PowerShell 7、Python 3 與 Git：

```powershell
pwsh -NoProfile -File tools/btr.ps1 -Task Compose -Python '<python.exe>'
pwsh -NoProfile -File tools/btr.ps1 -Task Setup -Python '<python.exe>' -SeedRoot '<同 repository 且 inputs 相同的既有工作樹>'
pwsh -NoProfile -File tools/btr.ps1 -Task Core -Python '<python.exe>'
```

完整 Flutter 專案產生於 `.assembled/app/`；直接修改 `BTR/` 或 `integration/` 的來源，重新組合到新的輸出目錄。產生的專案不作為維護來源，既有輸出不會被覆寫。
