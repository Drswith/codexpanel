# tokscale 独立统计引擎

Codex Panel 的 App 包只包含下载清单、许可证和离线价格种子，不包含 tokscale 二进制。固定版本及来源校验值见 `tokscale-manifest.json`，由 Xcode 原生 Copy Resources 复制为 `Contents/Resources/tokscale-manifest.json`，供用户手动下载安装时读取。

- 默认优先使用兼容的系统已安装引擎，再使用 App 管理目录中的已有副本。用户可选择仅供 Codex Panel 使用的专用副本，App 会记住选择。缺少兼容引擎时显示安装入口，不会自动下载。
- 手动下载的专用副本位于当前 profile 的 `codexBarRoot/engines/tokscale/` 下，不修改 `PATH`，不进行全局安装。Debug 和 `CODEXPANEL_HOME` 沿用开发态隔离，不写正式 profile。
- 专用副本的运行依赖只有 macOS 系统库，无需 Node、Bun、npm 或 Rust。可选的 `libFoundationModels.dylib` 不用于用量统计，因此不下载。系统已有安装的依赖由其安装方式决定。
- 固定版本的 Mach-O 最低系统声明：arm64 为 macOS 11.0，x86_64 为 10.13；App 最低要求仍为 macOS 13.0。两个架构均没有 FoundationModels dylib 的强/弱加载项。这里是二进制静态检查，旧系统运行验证仍需在对应系统执行。
- 上游 MIT 许可证原文保存在 `tokscale-LICENSE.txt`，随 App 复制为 `Contents/Resources/tokscale-LICENSE.txt`。初始离线价格子集来自 LiteLLM，其固定来源记录与价格资源一同保存；MIT 许可证位于 `ThirdParty/litellm/litellm-LICENSE.txt`，复制为 `Contents/Resources/litellm-LICENSE.txt`。
- App 构建没有引擎下载步骤，不需要 Python 或 npm。universal 发行只合并 App 的代码；`scripts/verify_release_artifacts.sh` 拒绝随包的 tokscale 文件或符号链接，并核对下载清单和许可证。
- 可选开发工具 `scripts/prepare_tokscale.py` 需要 Python 3 和 curl，仅预取测试引擎到 `.build/tokscale/<version>/<arch>/`，不支持向 App 打包。它验证 npm tarball 的 SHA-512，再校验解出的二进制 SHA-256，只提取固定路径，不执行 npm 安装脚本；沿用命令环境的代理配置，不设置固定代理。
- 需要真实引擎集成测试时，可运行 `python3 scripts/prepare_tokscale.py --arch arm64`（Intel 使用 `x86_64`），并在测试 runner 环境中将 `CODEXPANEL_TEST_TOKSCALE_PATH` 指向缓存中的二进制绝对路径；未设置时跳过该项测试。

升级下载版本时同时更新版本、commit、两个平台包的 integrity 和二进制 SHA-256，核对上游许可证，并重新运行隔离日志统计与产物校验。二进制不提交到 Git。
