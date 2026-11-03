# ChatGPT Backdrop — 繁體中文說明

介面與主要說明文件以英文為優先。[English README](README.md)

原創、非官方的 Mac 圖片背景工具。可選自己的圖片，調整遮罩、模糊、面板透明度與圖片位置，並恢復 ChatGPT 原本的外觀。

## 1.1.5 — 整合面板覆蓋修正

整合底部縫隙、工作模式面板透明度、Dots 背景及多視窗支援。套用背景時，更新後的樣式引擎會替換先前已載入的版本。

## 1.1.4 — Dots 背景

自訂背景可穿透 Dots 頁面的內外兩層訊息容器，頁尾底色與裝飾漸層也會透明。訊息氣泡、附件、表情反應及輸入控制項保留原生樣式；Restore Original 會移除這些覆寫。

## 1.1.0 — GIF 動態背景與 Logo

- 可選擇 GIF 當背景，並在工具中播放預覽。
- GIF 不會轉成單張圖片，儲存及匯入主題會保留原始動畫、時間與循環設定。
- 調整同一張 GIF 的透明度、模糊、位置及切換原生深淺色時，不會重頭播放。
- 加入全新 Backdrop Logo，包含介面標誌、PNG 與 macOS App 圖示；設計提示詞收錄於 [Brand](Brand/README.md)。
- 保留 1.0.2 已修正的側欄、透明度及輸入區效果。

GIF 選擇器與動畫預覽需要開啟新版 App。若舊版仍在執行，先儲存主題再結束舊版。若想沿用目前的 ChatGPT 連線，先記下舊版 Advanced 區的 **Local Port**，在新版填入同一個埠號並按 **Connect**，即可套用而無須重新啟動 ChatGPT。

## 1.1.1 標題列遮罩

Panel Opacity 的半透明遮罩會向上延伸到左側標題列，包含導覽列，並隨側欄寬度變動；保留上方按鈕點擊、拖曳與既有 GIF 支援。

## 1.1.2 底部縫隙修正

移除原生頁面外框的底部留白，讓 Panel Opacity 延伸至視窗底部；側欄收合成導覽列時也適用。保留原生頂部位置、右側留白、內層底部控制項間距與圓角。

## 1.1.3 工作模式面板透明度

Panel Opacity 現在也會控制 Edit environment 按鈕、Choose project / This computer 工具列，以及 Outputs / Subagents / Sources 摘要卡片。摘要標題不再重複疊加不透明底色。浮動工具列、原本未填色的摘要、項目懸停狀態、對話框和選單保留原本樣式。

## 1.0.2 修正

- 清除側邊欄向右延伸 20 CSS px 的原生裝飾底色，修正殘留的垂直深色帶。
- 清除主內容左緣的視覺細分隔線，保留拖曳調整寬度的控制項與作用區域。
- 保留 1.0.1 其餘已修正的透明度、頂部／輸入區遮罩與輸入行為。

## 1.0.1 修正

- 側邊欄只填一層半透明背景，內層導覽與標題保持透明。
- 清除原生空裝飾層的頁面陰影、頂部漸層與輸入區外圍底色，保留對話內容和控制項。
- 輸入框與預覽會依 Panel Opacity 顯示，不再強制至少 72% 不透明度。
- 保留選單、文件／行內編輯器、程式碼區塊及其他卡片的原生陰影。

如果這個對話建立的舊工具仍在開啟並連接中，按 **Apply Background** 即可重載已更新的樣式引擎，無須重新啟動 ChatGPT。完整新版下載也包含修正後的預覽介面。

## 開啟與使用

1. 先執行 `zsh build.sh`，再雙擊產生的 **ChatGPT Backdrop.app**。
2. 按 **Choose Background…** 選擇本機圖片或 GIF，或先用內附的 Twilight Hills 範例。
3. 調整右側滑桿；**Save Theme…** 可將圖片和設定一起存成 JSON，下次再用 **Import Theme…** 匯入。
4. 等 ChatGPT 目前的工作完成，再按 **Apply Background**。**首次套用會要求確認重新啟動 ChatGPT，這會中斷目前工作。**
5. 按 **Restore Original** 可清除背景；正常結束工具時也會嘗試清除。

圖片會在本機縮放，沒有上傳、分析對話或自動啟動服務。主題檔包含完整圖片，請自行決定儲存與分享的位置。

使用 **Open in New Window** 開啟的聊天視窗，也會自動套用目前背景，通常在兩秒內完成。連接時已開啟的聊天視窗也會納入；調整設定、**Restore Original** 與結束工具會處理所有已管理的聊天視窗。關閉原始視窗後，其他聊天視窗仍會繼續更新。一般視窗輪詢不會重新套用相同背景，因此不會持續重啟 GIF。

多視窗支援需要重新編譯並開啟新版 Backdrop。結束舊版前，先儲存主題並記下 **Local Port**；新版使用該連接埠 **Connect** 並匯入主題，可沿用目前的 ChatGPT 連線，不必重新啟動 ChatGPT。

## 支援範圍

- 此附帶成品為 **Apple Silicon / macOS 14 以上**版本。
- 針對 `/Applications/ChatGPT.app`、Bundle ID `com.openai.codex` 的新版桌面介面製作；已依本機版本 `26.1023.51421` 的介面結構設計。
- 處理 `app://-/index.html` 聊天視窗，包含 **Open in New Window**；排除內嵌瀏覽器、其他來源、獨立的 `detached-window.html` 瀏覽器外殼，以及寵物、聽寫、Spotlight 和快捷鍵工具視窗。套用與還原都保留應用程式來源及頂層框架檢查。
- 不修改 ChatGPT 的安裝檔案、不修改登入資料、不關閉系統防護。
- 套用後需要保留工具開啟。ChatGPT 結束後，本次注入就會失效；下次可重新匯入主題並套用。
- 恢復外觀不會停用已開啟的本機偵錯連接埠。要停用該連線，請關閉 ChatGPT，再正常重新開啟。
- ChatGPT 更新可能改變介面結構，因此不保證所有版本相容。App 驗證或連線失敗時會停止套用並顯示原因。

## 自行編譯

使用 macOS 內建框架及 Xcode Command Line Tools，不需安裝第三方套件：

```sh
zsh build.sh
```

成品是本機 adhoc 簽署版本，未經 Apple 公證。原始碼在 `Sources/`，建置過程不會下載或執行外部安裝程式。

## 驗證

```sh
zsh Tests/run.sh          # 只連線至測試程式自己的 127.0.0.1 模擬服務
zsh Tests/run-theme.sh    # 獨立 WebKit 記憶體頁面，驗證樣式套用與還原
zsh Tests/run-windows.sh  # 離線多視窗探索、設定更新與清理
```

測試不會連接、重啟或修改 ChatGPT。測試環境與結果請見 `Tests/README.md`。

已驗證工具介面、本機傳輸與獨立頁面測試。回歸測試依照目前 App 的側欄延伸區、拖曳控制項、陰影與輸入框結構建立；由於電腦操作工具禁止直接檢視 ChatGPT 視窗，實際視覺效果仍需你套用後確認。

## 實作依據

以 SwiftUI、AppKit、URLSession 和原創 JavaScript 實作，透過本機 Chrome DevTools Protocol 套用可移除的樣式；沒有複製其他換膚專案的程式碼。

- [Electron 的遠端偵錯參數](https://www.electronjs.org/docs/latest/api/command-line-switches#--remote-debugging-portport)
- [Chrome DevTools Protocol](https://chromedevtools.github.io/devtools-protocol/)
- [Apple Code Signing](https://developer.apple.com/library/archive/technotes/tn2206/_index.html)

原始碼採 MIT 授權；見 `LICENSE`。
