# 本次更新

- 围绕本轮对话里的 OpenAI 聚合模式问题，收敛了 aggregate / switch 的菜单文案与切换入口。
- 让 OpenAI OAuth 在账号同步时保留原生 ChatGPT auth 与 `service_tier`，避免 aggregate 模式把 Codex 原生 fast mode 压平。
- 为 aggregate gateway 的 `responses` / `responses/compact` 路径补齐 `service_tier` 透传回归测试。
- 调整 OpenAI 账号排序，在加权额度相同时优先更早重置的账号。
- 修正 OpenAI Accounts 头部布局，避免标题被模式切换按钮挤压，并让右侧控件与账号行操作列重新对齐。

# 受影响文件

- `codexPanel/Localization.swift`
- `codexPanel/Models/CodexPanelConfig.swift`
- `codexPanel/Models/OpenAIAccountListLayout.swift`
- `codexPanel/Services/CodexSyncService.swift`
- `codexPanel/Services/OpenAIAccountGatewayService.swift`
- `codexPanel/Views/MenuBarView.swift`
- `codexPanelTests/CodexPanelOpenAIAccountUsageModeTests.swift`
- `codexPanelTests/CodexSyncServiceTests.swift`
- `codexPanelTests/OpenAIAccountGatewayServiceTests.swift`
- `codexPanelTests/OpenAIAccountListLayoutTests.swift`
