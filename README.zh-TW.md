# ChatGPT Backdrop — 繁體中文說明

介面與主要說明文件以英文為優先。[English README](README.md)

原創、非官方的 Mac 圖片背景工具。可選自己的圖片，調整遮罩、模糊、面板透明度與圖片位置，並恢復 ChatGPT 原本的外觀。

## 1.2.7 — 閱讀圖層流暢度

每一輪閱讀圖層更新會重用原生位置量測，先完成讀取再一起寫入卡片樣式，捲動時不再重寫沒有改變的底色等設定。閱讀更新也會合併到既有的畫面更新排程，減少重複計算。透明度、模糊、GIF 播放和原生控制項維持所選效果。

## 1.2.6 — 新版 ChatGPT 樣式相容性

支援 ChatGPT 26.1029.61003 新的內部樣式名稱，同時保留舊版格式。修正更新後重新出現的頂部陰影、頁尾漸層，並維持輸入框透明度、側欄細線及 Dots 標題漸層的既有修正。請使用新版 Backdrop 套用，以替換先前載入的樣式引擎。

## 1.2.5 — Dots 閱讀模式

Sheet、Cards 與 Focus 現在也支援 Dots 聊天室，Reading Opacity 與 Reading Blur 會獨立控制閱讀效果，避免助理訊息原有底色重疊。使用者訊息的 Accent 顏色、反應、附件與控制項維持原生樣式。選 None 可還原原先外觀並保留桌布；Restore Original 會移除背景與所有閱讀效果。

## 1.2.4 — 設定頁背景

主要設定頁會顯示選定的桌布，卡片、控制項、預覽及底部操作區保留原生外觀。已掛載的設定頁隱藏或重新顯示時，桌布會自動更新。內嵌設定與對話框維持原本樣式；Restore Original 會恢復設定頁底色。

## 1.2.2 — 原生 Accent 配色

保留淺色與深色模式下送出／停止按鈕、焦點框與使用者訊息的原生 Accent 顏色。Panel Opacity 只調整輸入框底色；背景套用期間切換 Accent，原生控制項也會即時更新。請使用新版 App 套用，以替換先前的樣式引擎。

## 1.2.1 — Dots 上方漸層

清除 ChatGPT 26.1027.61615 在 Dots 工具列下方另外繪製的裝飾漸層，保留標題按鈕、個人資料控制項及定位設定。Restore Original 會恢復原生漸層。

## 1.2.0 — 閱讀模式

Build 10 在既有背景控制項之外加入可選的閱讀效果。

新增 **Reading Mode**，提供四個單字選項：

- **None**：保留原本外觀；舊主題也預設使用這個模式。
- **Sheet**：在聊天欄後方放一整片半透明閱讀底板。
- **Cards**：為回覆與工具群組分別加上閱讀卡片。
- **Focus**：在聊天室中央加上柔和底色，邊緣漸淡，不加卡片框線。

**Reading Opacity** 與 **Reading Blur** 獨立控制閱讀效果，不影響側欄的 Panel Opacity。文字與按鈕維持清晰，閱讀底板會跟隨實際聊天欄寬度與捲動範圍；選 None 可移除閱讀效果並保留桌布。設定會隨主題儲存與匯入。沒有辨識到聊天欄的新頁面或不支援畫面不會加入底板。

四選項需要開啟新版 App。舊版仍連接中時，先儲存主題並記下 **Advanced → Local Port**，再結束舊版；新版填入同一個埠號按 **Connect**，匯入主題並套用，即可沿用連線而無須重啟 ChatGPT。

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
3. 調整右側滑桿並選擇 **None / Sheet / Cards / Focus**；**Save Theme…** 可將圖片和設定一起存成 JSON，下次再用 **Import Theme…** 匯入。
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
zsh Tests/run-media.sh    # GIF 保留與靜態圖片解碼
zsh Tests/run-windows.sh  # 離線多視窗探索、設定更新與清理
zsh Tests/run-settings.sh # 舊主題相容性與閱讀模式序列化
node --test .github/scripts/codex-gate.test.cjs # 自動合併規則
```

測試不會連接、重啟或修改 ChatGPT。測試環境與結果請見 [Tests/README.md](Tests/README.md)。PR 會在 macOS CI 執行測試，並遵循 [Codex 審查與自動合併規則](.github/AUTOMATION.md)。

已驗證工具介面、本機傳輸與獨立頁面測試。回歸測試依照目前 App 的側欄延伸區、拖曳控制項、陰影與輸入框結構建立；由於電腦操作工具禁止直接檢視 ChatGPT 視窗，實際視覺效果仍需你套用後確認。

## 實作依據

以 SwiftUI、AppKit、URLSession 和原創 JavaScript 實作，透過本機 Chrome DevTools Protocol 套用可移除的樣式；沒有複製其他換膚專案的程式碼。

- [Electron 的遠端偵錯參數](https://www.electronjs.org/docs/latest/api/command-line-switches#--remote-debugging-portport)
- [Chrome DevTools Protocol](https://chromedevtools.github.io/devtools-protocol/)
- [Apple Code Signing](https://developer.apple.com/library/archive/technotes/tn2206/_index.html)

原始碼採 MIT 授權；見 `LICENSE`。
