#!/usr/bin/env python3
"""校验 codexpanel Pull Request 的标题与正文规范。"""

from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path


ALLOWED_TYPES = (
    "feat",
    "fix",
    "refactor",
    "perf",
    "docs",
    "test",
    "build",
    "ci",
    "chore",
    "style",
    "revert",
    "release",
)
REQUIRED_SECTIONS = (
    "变更说明",
    "变更类型",
    "验证",
    "风险与回滚",
    "关联问题",
    "提交前确认",
)
TITLE_PATTERN = re.compile(
    rf"^(?P<kind>{'|'.join(ALLOWED_TYPES)})"
    r"(?P<scope>\([^()\s:]+\))?"
    r"(?P<breaking>!)?:\s+(?P<description>\S(?:.*\S)?)$"
)
HEADING_PATTERN = re.compile(r"(?m)^##[ \t]+(?P<name>[^\r\n]+?)[ \t]*$")
CHECKBOX_PATTERN = re.compile(
    r"^\s*-\s*\[(?P<mark>[ xX])\]\s+(?P<label>.+?)\s*$"
)
PLACEHOLDER_PATTERN = re.compile(
    r"(?i)\b(?:todo|tbd)\b|待填写|待补充|请填写|(?:\.\.\.|…{2,})"
)
ISSUE_REFERENCE_PATTERN = re.compile(
    r"#\d+|https?://\S+/(?:issues|discussions)/\d+|"
    r"(?:无|无需关联|不适用)|\b(?:none|n/a|na)\b",
    re.IGNORECASE,
)


def _without_comments(text: str) -> str:
    return re.sub(r"<!--.*?-->", "", text, flags=re.DOTALL)


def _checkboxes(text: str) -> list[re.Match[str]]:
    return [
        match
        for match in (
            CHECKBOX_PATTERN.match(line) for line in text.splitlines()
        )
        if match is not None
    ]


def _meaningful_lines(text: str) -> list[str]:
    lines: list[str] = []
    for raw_line in _without_comments(text).splitlines():
        line = raw_line.strip()
        if not line or re.match(r"^#{1,6}\s", line):
            continue
        if CHECKBOX_PATTERN.match(line):
            continue
        lines.append(line)
    return lines


def _meaningful_text(text: str) -> str:
    return "\n".join(_meaningful_lines(text))


def _parse_sections(body: str) -> dict[str, list[str]]:
    normalized_body = body.replace("\r\n", "\n")
    matches = list(HEADING_PATTERN.finditer(normalized_body))
    sections: dict[str, list[str]] = {}
    for index, match in enumerate(matches):
        end = (
            matches[index + 1].start()
            if index + 1 < len(matches)
            else len(normalized_body)
        )
        name = match.group("name").strip()
        sections.setdefault(name, []).append(normalized_body[match.end() : end])
    return sections


def validate_title(title: str) -> list[str]:
    errors: list[str] = []
    if not title:
        return ["标题不能为空。"]
    if title != title.strip():
        errors.append("标题不能以空格开头或结尾。")
    if "\n" in title or "\r" in title:
        errors.append("标题必须保持为单行。")

    match = TITLE_PATTERN.fullmatch(title)
    if match is None:
        errors.append(
            "标题必须使用 `type(scope): 简短描述` 格式；type 可选："
            + ", ".join(ALLOWED_TYPES)
            + "。"
        )
    else:
        description = match.group("description")
        if len(description) < 4:
            errors.append("标题描述至少需要 4 个字符，不能使用过于笼统的标题。")
    if len(title) > 80:
        errors.append("标题不能超过 80 个字符。")
    if re.search(r"(?i)\b(?:wip|todo|tbd)\b", title):
        errors.append("标题不能使用 WIP、TODO 或 TBD 作为占位内容。")
    return errors


def _validate_required_sections(sections: dict[str, list[str]]) -> list[str]:
    errors: list[str] = []
    for section in REQUIRED_SECTIONS:
        values = sections.get(section, [])
        if not values:
            errors.append(f"缺少必填章节 `## {section}`。")
        elif len(values) > 1:
            errors.append(f"章节 `## {section}` 只能出现一次。")
    return errors


def _validate_body_sections(sections: dict[str, list[str]]) -> list[str]:
    errors: list[str] = []

    summary = sections.get("变更说明", [""])[0]
    summary_text = _meaningful_text(summary)
    if len(re.sub(r"\s+", "", summary_text)) < 8:
        errors.append("`变更说明` 需要填写至少 8 个字符的实际内容。")
    elif PLACEHOLDER_PATTERN.search(summary_text):
        errors.append("`变更说明` 不能保留 TODO、待填写或省略号等占位内容。")

    change_types = _checkboxes(sections.get("变更类型", [""])[0])
    if not any(match.group("mark").lower() == "x" for match in change_types):
        errors.append("`变更类型` 至少需要勾选一项。")
    for match in change_types:
        if (
            match.group("mark").lower() == "x"
            and re.fullmatch(r"其他[:：]?\s*", match.group("label"))
        ):
            errors.append("勾选“其他”类型时，需要补充具体类型。")

    verification = sections.get("验证", [""])[0]
    verification_checkboxes = _checkboxes(verification)
    checked_verification = [
        match
        for match in verification_checkboxes
        if match.group("mark").lower() == "x"
    ]
    if not checked_verification:
        errors.append("`验证` 至少需要勾选一项。")
    for match in checked_verification:
        label = match.group("label")
        if "未运行验证" not in label:
            continue
        reason_match = re.search(r"原因[:：]\s*(?P<reason>.*)$", label)
        reason = reason_match.group("reason").strip() if reason_match else ""
        reason = reason.strip("（）()：:，,；;。. \t")
        if not reason or PLACEHOLDER_PATTERN.search(reason):
            errors.append("勾选“未运行验证”时，需要在该项中说明原因。")

    verification_without_comments = _without_comments(verification)
    result_match = re.search(
        r"(?mi)^\s*验证结果[:：]\s*(?P<result>.*)$",
        verification_without_comments,
    )
    if result_match is None:
        errors.append("`验证` 需要包含 `验证结果：`。")
    else:
        result = result_match.group("result").strip()
        if not result:
            result = verification_without_comments[result_match.end() :].strip()
        if not result or PLACEHOLDER_PATTERN.search(result):
            errors.append("`验证结果：` 后需要填写实际命令、结果或未运行的原因。")

    risk = _meaningful_text(sections.get("风险与回滚", [""])[0])
    if not risk:
        errors.append("`风险与回滚` 需要填写内容；没有风险时请填写“无”。")
    elif PLACEHOLDER_PATTERN.search(risk):
        errors.append("`风险与回滚` 不能保留占位内容。")

    issue = _meaningful_text(sections.get("关联问题", [""])[0])
    if not issue:
        errors.append("`关联问题` 需要填写 issue 引用，或明确填写“无”。")
    elif not ISSUE_REFERENCE_PATTERN.search(issue):
        errors.append("`关联问题` 需要包含 `#编号`、issue URL，或“无/无需关联”。")

    confirmation = _checkboxes(sections.get("提交前确认", [""])[0])
    if not confirmation:
        errors.append("`提交前确认` 需要保留并完成确认清单。")
    else:
        unchecked = [match.group("label") for match in confirmation if match.group("mark") == " "]
        if unchecked:
            errors.append("`提交前确认` 仍有未勾选项：" + "；".join(unchecked))

    return errors


def validate_body(body: str) -> list[str]:
    if not body.strip():
        return ["PR 正文不能为空。"]
    sections = _parse_sections(body)
    errors = _validate_required_sections(sections)
    if errors:
        return errors
    return _validate_body_sections(sections)


def validate_pr(title: str, body: str) -> list[str]:
    return [f"标题：{error}" for error in validate_title(title)] + [
        f"正文：{error}" for error in validate_body(body)
    ]


def _read_arguments() -> tuple[str, str]:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--event-file", type=Path, help="GitHub 事件 JSON 文件")
    parser.add_argument("--title", help="本地校验使用的 PR 标题")
    parser.add_argument("--body", help="本地校验使用的 PR 正文")
    parser.add_argument("--body-file", type=Path, help="从文件读取 PR 正文")
    args = parser.parse_args()

    if args.event_file is not None:
        event = json.loads(args.event_file.read_text(encoding="utf-8"))
        pull_request = event.get("pull_request") or {}
        return str(pull_request.get("title") or ""), str(pull_request.get("body") or "")

    if args.title is None:
        parser.error("本地校验需要同时提供 --title 和 --body/--body-file，或提供 --event-file。")
    if args.body_file is not None and args.body is not None:
        parser.error("--body 与 --body-file 不能同时使用。")
    if args.body_file is not None:
        body = args.body_file.read_text(encoding="utf-8")
    elif args.body is not None:
        body = args.body
    else:
        parser.error("本地校验需要提供 --body 或 --body-file。")
    return args.title, body


def main() -> int:
    title, body = _read_arguments()
    errors = validate_pr(title, body)
    if errors:
        print("PR 元数据门禁失败：", file=sys.stderr)
        for error in errors:
            print(f"- {error}", file=sys.stderr)
        return 1
    print("PR 元数据门禁通过。")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
