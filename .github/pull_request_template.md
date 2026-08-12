## 变更说明

<!-- 请说明为什么改、改了什么，以及这次变更给用户或维护者带来的结果。不要只粘贴 commit 列表。 -->

## 变更类型

- [ ] `feat` 新功能
- [ ] `fix` 问题修复
- [ ] `refactor` 重构
- [ ] `perf` 性能优化
- [ ] `docs` 文档
- [ ] `test` 测试
- [ ] `build` 构建
- [ ] `ci` CI / 工程化
- [ ] `chore` 维护
- [ ] `style` 格式 / 样式
- [ ] `revert` 回滚
- [ ] `release` 发布准备
- [ ] 其他：

## 验证

<!-- 请勾选实际执行过的验证，并在“验证结果”中写明命令和结果。仅文档、配置或流程变更也要明确说明。 -->

- [ ] `swift test --package-path Packages/CodexPanelCore`
- [ ] `xcodebuild -project codexpanel.xcodeproj -scheme codexpanel -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO test`
- [ ] 仅文档、配置或流程变更，无需运行应用测试
- [ ] 未运行验证（原因：）

验证结果：

## 风险与回滚

<!-- 请说明兼容性、数据或发布风险，以及必要时的回滚方式；没有风险请明确填写“无”。 -->

## 关联问题

<!-- 请填写 #123、Closes #123 或对应 issue URL；没有关联 issue 请填写“无”并说明原因。 -->

## 提交前确认

- [ ] 标题遵循 `type(scope): 简短中文描述` 格式，且准确概括本次变更
- [ ] 变更说明与实际 diff 一致，没有混入无关改动
- [ ] 验证命令和结果已如实填写
- [ ] 已检查敏感信息、凭据和本地环境文件，没有提交到仓库
