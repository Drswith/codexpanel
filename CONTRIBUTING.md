# 贡献指南

## Pull Request

Pull Request 默认使用简体中文说明，标题和正文由仓库门禁统一校验。

标题使用 Conventional Commit 风格：

```text
type(scope): 简短描述
```

允许的 `type` 为 `feat`、`fix`、`refactor`、`perf`、`docs`、`test`、`build`、`ci`、`chore`、`style`、`revert` 和 `release`。`scope` 可选；标题可以使用 `!` 标记破坏性变更，描述应具体、单行且不超过 80 个字符。

正文请从 [PR 模板](.github/pull_request_template.md) 开始，并完整填写变更说明、变更类型、验证、风险与回滚、关联问题和提交前确认。验证章节必须记录实际执行的命令和结果；如果没有关联 issue，请明确填写“无”或“无需关联”。

`PR 门禁 / 标题与正文` 会在 PR 创建、编辑、更新提交、重新打开和标记为 ready for review 时运行。校验失败时，请按检查输出修正标题或正文后重新提交；仓库管理员应将该检查加入 `main` 分支的 required status checks，才能把它作为合并门禁。

## 本地校验

可以在不打开 GitHub 的情况下运行校验器和测试：

```sh
python3 -m unittest discover -s scripts/tests -p 'test_*.py'
python3 scripts/validate_pr.py \
  --title 'ci(governance): 收敛 PR 标题和内容门禁' \
  --body-file .github/pull_request_template.md
```

第二条命令预期会失败，因为模板中的待填写项尚未完成；提交前应使用填写完整的正文重新运行。
