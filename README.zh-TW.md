<div align="center">

<img src="site/assets/icon.png" width="112" alt="MailSift app 圖示">

# MailSift

**開源 · 本地 · 語意搜尋**

在 Mac 上用意思搜尋你所有的 Apple Mail。

[**下載**](https://github.com/t42ji2ji/mailsift/releases/latest) · [官網](https://mailsift.dorara.app) · [English](README.md)

</div>

## 功能

**用意思搜尋。** 描述要找的信（「京都飯店的發票」），即使信裡用的是別的字、別的語言也找得到。本機模型（EmbeddingGemma 2，Core ML）加上關鍵字搜尋一起用。還沒建完索引就能搜，從最新的信開始。

**更快的信箱。** 收件匣、旗標、封存、垃圾桶、垃圾郵件，依日期分區。列表鍵盤操作：`j`／`k` 上下、`e` 封存、`#` 丟垃圾桶、`s` 旗標、`u` 已讀／未讀、`r`／`R` 回覆、`f` 轉寄。

**照用途分類。** 每封信都在你的 Mac 上自動標好用途：工作、關係、交易、通知、開發、電子報、促銷。點列表上方的類別就只看那一類；在設定裡可以排序、隱藏，或用一句描述加上自己的類別。

**依寄件者清理。** 看誰寄最多，選好寄件者，一次把他們的信全部移到垃圾桶。

**用你已經在用的 AI。** 按 ⌘J，請 Mac 上的 [Claude Code](https://code.claude.com/docs/en/setup) 或 [Codex](https://developers.openai.com/codex/cli) 處理信件，用你自己的登入，不用另外申請 API 金鑰。它透過 MailSift 搜尋和讀信，但只能**提議**變更：每封信列出勾選框和理由，你取消不要的、再確認。它也能替打開的信起草回覆，草稿會在 Mail 開啟，不會替你寄出。對話會保留下來，可以從歷史接著聊。

**給你自己的 agent。** App 內附 `mailsift` 指令列工具和 MCP server：

```sh
/Applications/MailSift.app/Contents/Helpers/mailsift mcp      # stdio 上的 MCP server
/Applications/MailSift.app/Contents/Helpers/mailsift search "改機票" --json
```

## 安裝

從 [Releases](https://github.com/t42ji2ji/mailsift/releases/latest) 下載 `.dmg`，把 MailSift 拖進「應用程式」。需要 Apple Silicon、macOS 15 以上，並且 Apple Mail 已經設定好帳號。

MailSift 直接讀 Mail 存在磁碟上的資料，所以需要**完全取用磁碟**權限（系統設定 › 隱私權與安全性），也因此沒有上 App Store。封存、刪除等動作由 Mail 執行，macOS 會問一次是否允許 MailSift 控制 Mail。第一次建索引會下載搜尋模型（約 570 MB）。

## 隱私

信件的索引和搜尋都在你的 Mac 上。MailSift 只有兩種情況會連網：從 Hugging Face 下載搜尋模型；以及使用 AI 側欄時，agent 讀到的信會透過你自己的 Claude Code 或 Codex 送到 Anthropic 或 OpenAI。

## 從原始碼建置

需要 Xcode 16 command line tools。

```sh
./build.sh        # 產生 build/MailSift.app
swift test
```

把 `build.sh` 和 `release.sh` 裡的簽章身分換成你自己的。

## 授權

GPL-3.0。`Sources/EmbedKit` 改自 [FluidUse](https://github.com/FluidInference/FluidUse)（Apache 2.0，見 `Sources/EmbedKit/NOTICE.md`）。Claude 和 OpenAI 標誌來自 Simple Icons（CC0），商標屬於各自的擁有者。
