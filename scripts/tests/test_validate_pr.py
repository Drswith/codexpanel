from __future__ import annotations

import sys
import unittest
from pathlib import Path


SCRIPTS_DIR = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SCRIPTS_DIR))

from validate_pr import validate_body, validate_pr, validate_title  # noqa: E402


VALID_TITLE = "ci(governance): 收敛 PR 标题和内容门禁"
VALID_BODY = """## 变更说明

新增 PR 模板和元数据校验，统一标题格式与正文必填信息，降低评审沟通成本。

## 变更类型

- [x] `ci` CI / 工程化

## 验证

- [x] 仅文档、配置或流程变更，无需运行应用测试

验证结果：已运行 Python 单元测试和门禁脚本正反例校验，全部通过。

## 风险与回滚

无运行时风险；如需调整规则，可回滚本次工作流与校验脚本。

## 关联问题

无，本次为仓库协作流程改进。

## 提交前确认

- [x] 标题遵循 `type(scope): 简短中文描述` 格式，且准确概括本次变更
- [x] 变更说明与实际 diff 一致，没有混入无关改动
- [x] 验证命令和结果已如实填写
- [x] 已检查敏感信息、凭据和本地环境文件，没有提交到仓库
"""


class ValidatePRTests(unittest.TestCase):
    def test_accepts_conventional_chinese_title(self) -> None:
        self.assertEqual(validate_title(VALID_TITLE), [])
        self.assertEqual(validate_title("feat!: 移除旧入口"), [])
        self.assertEqual(validate_title("docs(发布): 同步发布说明"), [])

    def test_rejects_unstructured_title(self) -> None:
        errors = validate_title("修一下")
        self.assertTrue(errors)
        self.assertIn("type(scope)", errors[0])

    def test_accepts_completed_body(self) -> None:
        self.assertEqual(validate_body(VALID_BODY), [])
        self.assertEqual(validate_pr(VALID_TITLE, VALID_BODY), [])

    def test_requires_checked_change_type_and_verification(self) -> None:
        body = VALID_BODY.replace("- [x] `ci`", "- [ ] `ci`")
        body = body.replace("- [x] 仅文档", "- [ ] 仅文档")
        errors = validate_body(body)
        self.assertTrue(any("变更类型" in error for error in errors))
        self.assertTrue(any("验证` 至少需要" in error for error in errors))

    def test_requires_completed_confirmation(self) -> None:
        body = VALID_BODY.replace("- [x] 已检查敏感信息", "- [ ] 已检查敏感信息")
        errors = validate_body(body)
        self.assertTrue(any("提交前确认" in error for error in errors))

    def test_requires_issue_reference_or_explicit_none(self) -> None:
        body = VALID_BODY.replace("无，本次为仓库协作流程改进。", "待补充。")
        errors = validate_body(body)
        self.assertTrue(any("关联问题" in error for error in errors))

    def test_requires_validation_result(self) -> None:
        body = VALID_BODY.replace(
            "验证结果：已运行 Python 单元测试和门禁脚本正反例校验，全部通过。",
            "验证结果：",
        )
        errors = validate_body(body)
        self.assertTrue(any("验证结果" in error for error in errors))

    def test_requires_reason_when_validation_was_not_run(self) -> None:
        body = VALID_BODY.replace(
            "- [x] 仅文档、配置或流程变更，无需运行应用测试",
            "- [x] 未运行验证（原因：）",
        )
        errors = validate_body(body)
        self.assertTrue(any("未运行验证" in error for error in errors))


if __name__ == "__main__":
    unittest.main()
