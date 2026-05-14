# updates.json 实现契约

## 目标

`updates.json` 是 codexpanel 的主更新信源，用于避免直接依赖 GitHub Releases API（匿名访问可能限流 403）。

运行时地址应为：

- `https://github.com/Drswith/codexpanel/releases/latest/download/updates.json`

该地址始终绑定“最新已发布 release 资产”，不受 `main` 分支提前改文件影响。

## 结构约束

当前由 `scripts/release_local.sh` 生成，核心字段如下：

```json
{
  "schemaVersion": 1,
  "channel": "stable",
  "release": {
    "version": "1.4.3",
    "publishedAt": "2026-05-14T02:20:00Z",
    "summary": "v1.4.3",
    "releaseNotesURL": "https://github.com/Drswith/codexpanel/releases/tag/v1.4.3",
    "downloadPageURL": "https://github.com/Drswith/codexpanel/releases/tag/v1.4.3",
    "deliveryMode": "guidedDownload",
    "minimumAutomaticUpdateVersion": null,
    "artifacts": [
      {
        "architecture": "universal",
        "format": "dmg",
        "downloadURL": "https://github.com/Drswith/codexpanel/releases/download/v1.4.3/codexpanel-1.4.3-macOS.dmg",
        "sha256": "<sha256>"
      }
    ]
  }
}
```

## 一致性校验

每次发版至少核对以下一致性：

- `release.version` 与本次 tag 版本一致。
- `downloadURL` 中的 tag 与文件名一致。
- `sha256` 与同名资产校验文件一致。
- `releaseNotesURL` / `downloadPageURL` 指向同一 tag 页面。

## 回退策略

当 `updates.json` 获取失败时，客户端应回退到：

1. `https://github.com/<owner>/<repo>/releases/latest`（由重定向解析 tag）
2. `https://api.github.com/repos/<owner>/<repo>/releases`

排障原则：

- 优先修复 feed 或 latest 路径。
- 仅将 Releases API 作为最后兜底，不作为主路径。
