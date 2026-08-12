<p align="center">
   <img src="Onglai%20Resources/onglai-1024.png" align="center" width="160" height="160" />
   <br />
   <h1 align="center">Onglai 旺來</h1>
</p>

<p align="center">
A macOS app cleaner — uninstall apps completely, sweep out orphaned leftovers, thin universal binaries, and manage Homebrew, all in one place.
</p>

**Onglai (旺來)** is Taiwanese for pineapple — a homophone for "fortune arrives". Sweep the old out, let the good stuff in. 除舊佈新，旺來。

## About this project

Onglai is a maintained continuation of [Pearcleaner](https://github.com/alienator88/Pearcleaner) by **Alin Lupascu (alienator88)**, which entered maintenance mode in early 2026. The original design and the vast majority of the code are his work — if you find this app useful, consider [sponsoring him](https://github.com/sponsors/alienator88).

### What Onglai adds on top of Pearcleaner 5.4.3

- **Bug fixes with root causes found here**: app exiting immediately when launched via `open`/Raycast/Alfred (upstream #589), UI-wide jank caused by release-notes HTML parsing inside the SwiftUI view body, and the toolbar notice badge drifting out of the title bar on macOS 26
- **Deletion safety net**: user-content folders (`~/Documents`, `~/Desktop`, `~/Downloads`, `~/Public`, …) and scan roots can never be offered for deletion, no matter how fuzzy the name match — defense in depth against the "uninstalled an app, lost my documents" class of bugs
- **Adopted community fixes** that were pending upstream: macOS 26 scan performance, Homebrew `--no-quarantine` removal on brew ≥ 4.7, cask/tap handling, analytics via the formulae.brew.sh API, Sentinel deep-link hardening, and more
- **Fresh identity**: bundle ID `me.ysya.Onglai`, `onglai://` deep links, and the CLI is now `ong`

## Install

Grab the latest build from [Releases](https://github.com/ysya/Onglai/releases), unzip, and drop `Onglai.app` into `/Applications`. Current free releases are signed with the maintainer's Apple Development identity but cannot be notarized, so the first launch requires **System Settings → Privacy & Security → Open Anyway**.

Grant **Full Disk Access** when prompted so the cleaner can actually see app leftovers.

## Releasing

Free development-signed release:

```bash
ONGLAI_RELEASE_MODE=development \
ONGLAI_DEVELOPMENT_TEAM=ABCDE12345 \
scripts/release.sh 5.4.6
```

For a Gatekeeper-trusted release, use an active Apple Developer Program membership, a `Developer ID Application` identity, an app group registered to the distribution team, and `notarytool` credentials stored in the login keychain:

```bash
ONGLAI_DEVELOPMENT_TEAM=ABCDE12345 \
ONGLAI_NOTARY_PROFILE=onglai-notary \
scripts/release.sh 5.4.6
```

Both modes verify the app and helper signing team before publishing through a draft. Developer ID mode additionally requires notarization, stapling, and Gatekeeper acceptance.

## 中文簡介

Onglai（旺來）是 [Pearcleaner](https://github.com/alienator88/Pearcleaner) 的延續維護版：完整移除 app 與殘留檔、清理孤兒檔案、瘦身通用二進位、管理 Homebrew。原專案 2026 年初進入維護模式，絕大多數程式碼出自原作者 Alin Lupascu 之手。

在原版之上，Onglai 修掉了幾個查到根因的老 bug（`open`/Raycast 啟動即退出、release notes HTML 解析造成的全域卡頓、工具列圖示跑版），並加上**誤刪防護網**——使用者內容資料夾（文件、桌面、下載等）無論名稱怎麼匹配都不會出現在刪除清單裡。

安裝：從 [Releases](https://github.com/ysya/Onglai/releases) 下載解壓，拖進「應用程式」。目前免費發佈版使用維護者的 Apple Development 憑證簽章，但無法送 Apple 公證；首次開啟需要到 **系統設定 → 隱私權與安全性 → 強制打開**。安裝後請依提示授權**完全磁碟取用**。

## License

[Apache 2.0 with Commons Clause](LICENSE.md) — same terms as upstream. Free to use, modify, and share; may not be sold.

Pearcleaner © Alin Lupascu. Onglai modifications © ysya.
