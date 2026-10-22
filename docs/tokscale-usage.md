# 用量统计后端

Cost 汇总和趋势图通过 tokscale 获取数据，界面继续由 SwiftUI 实现。`TokenStore` 依赖 `LocalCostSummaryProviding`，统计实现为 `TokscaleCostSummaryService`。历史模型列表直接从当前摘要和自定义价格配置生成。原来的 `SessionLogStore` 继续服务会话归属等功能，旧 Swift 汇总器仅保留在测试目标中，不作为新后端失败时的回退。

## 启用与引擎来源

设置的用量页可独立启用本地统计，无需先添加账号。默认来源为 `installed`：启用后优先检查兼容的系统已安装引擎，再使用 App 管理目录的已有副本。用户也可选择专用副本，App 记住 `managed` 偏好。没有可用引擎时显示选择或下载安装入口，不会自动下载，也不会回退到 Swift 汇总器。

手动下载使用随包清单固定的官方 4.20.0 平台包，下载副本仅供 Codex Panel 使用，放在当前 profile 的 `codexBarRoot/engines/tokscale/<版本>/<架构>/tokscale`。正式 profile 的根目录为 `~/.codexpanel/engines/tokscale/`；默认 Debug profile 对应 `~/.codexpanel-dev/home/.codexpanel/engines/tokscale/`，自定义 `CODEXPANEL_HOME` 也沿用其隔离目录。不会安装到系统目录或修改 `PATH`。

关闭统计后隐藏菜单 Cost，取消扫描和价格更新，保留已有摘要。已明确启动的下载或版本检查可以完成，但不会自动重新启用统计。重新启用可以暂显旧结果，等待新统计完成。

## 运行与数据边界

- App 不捆绑引擎。选定的系统引擎或专用副本由 App 以参数数组启动 `graph --client codex --no-spinner`，通过 JSON 接收统计；没有 shell 拼接。
- `CODEX_HOME` 指向当前 runtime profile 的 `.codex`。独立 `HOME`、`OPENCODEX_HOME` 和 `TOKSCALE_CONFIG_DIR` 将辅助程序的配置及缓存限制在该 profile 的 `.codexpanel` 内，避免混入用户另行安装的 tokscale 配置或其他客户端数据。
- Debug 沿用 `CODEXPANEL_HOME` / 开发态隔离。统计过程不写 Codex 的认证和模型配置，不调用会话摘要、发布或上传命令。
- 扫描在后台串行执行，重复刷新合并成最多一次待处理请求；价格设置在扫描期间改变时，旧价格的结果不会覆盖新配置。进程有超时和输出大小上限。
- 打开菜单最多按一分钟间隔刷新，手动刷新和价格修改可以立即请求刷新。失败保留上次摘要，首次失败显示不可用，避免把错误展示成零用量。

## 价格与统计口径

扫描使用离线价格缓存，首次运行从随包的 LiteLLM 固定快照初始化。来源与固定 commit 记录在 `codexPanel/Resources/tokscale-pricing-seed-source.txt`。随后由官方 `pricing` 命令在同一串行队列中更新公共价格缓存，更新任务一小时节流、15 秒硬超时；不会阻塞界面，更新结果用于后续扫描。

设置页明确区分自动价格与自定义价格。自动模式由统计引擎更新价格；新建自定义价格先编辑草稿，点击应用后生效，也可以通过“恢复自动”删除覆盖。自定义价格转换为专用 `custom-pricing.json`，优先级及 Priority 等倍率由官方引擎处理，不再使用 Swift 的会话累计长上下文倍率。自定义价格与 LiteLLM 的长上下文分档语义由 tokscale 定义，不能假定与旧 Swift 规则相同。

总 token 对缓存输入和推理输出分别只计一次。每日汇总按官方请求起点和系统时区分桶；今日及最近 30 个日历日从每日结果计算。切换系统时区后重新生成缓存。未知价格保留 token 总量，在对应日期及汇总区间标记价格不完整；金额可显示已知部分的下限。

## 旧缓存迁移

旧摘要可以暂时显示，并标记等待重新统计；首次成功后以带 `source=tokscale-v4` 的新摘要替换。旧 Swift 会话缓存及账本不会删除、导入或相加，避免重复计数。统计范围由官方引擎当前可读取的日志及其缓存决定；此前仅保存在 Swift 账本、源日志已删除的历史不自动迁入。

模型切换、压缩日志、fork、计数器重置、Priority，以及跨午夜日期归属都可能使新结果与旧结果不同。离线价格快照和自定义价格提供成本估算，未知价格会单独展示。

## 构建与分发

`ThirdParty/tokscale/tokscale-manifest.json` 锁定 npm 官方 arm64 / x86_64 包的 URL、SHA-512 integrity 和二进制 SHA-256，由 Xcode 原生 Copy Resources 作为 `tokscale-manifest.json` 随包。App 还包含 tokscale 与 LiteLLM 的许可证、离线价格种子，不包含引擎二进制。

App 构建和 universal 合并不下载、复制或签名 tokscale；`scripts/verify_release_artifacts.sh` 主动拒绝包内的 tokscale 文件或符号链接，并核对清单和许可证。专用原生副本只需要支持的 macOS 系统库，无 Node、Bun、Python 或 Rust 运行时依赖；系统已有安装的运行依赖由其安装方式决定。

`scripts/prepare_tokscale.py` 仅用于开发者显式预取隔离集成测试所需的引擎，不是构建依赖，不支持向 App 打包。它只提取已校验的普通二进制文件，不运行 npm 安装脚本，缓存位于 `.build/tokscale/<version>/<arch>/`。这个可选工具需要 Python 3 和 curl；二进制不提交到 Git。

## 验证

新测试覆盖官方 JSON 映射、未知价格、时间边界、进程超时与环境隔离、旧缓存兼容、失败保留结果、扫描期间的价格修改和分发边界。真实引擎验收使用隔离的合成 `.codex`，不以真实用户会话作为测试输入。

真实引擎集成测试仅在设置 `CODEXPANEL_TEST_TOKSCALE_PATH` 时运行，缺失时跳过。可先执行 `python3 scripts/prepare_tokscale.py --arch arm64`（Intel 改为 `x86_64`），再将该变量设为 `.build/tokscale/4.20.0/<arch>/tokscale` 的绝对路径；在 Scheme 的 Test 环境变量中指定该值，或通过当前测试运行方式将它传入测试 runner。常规 CI 不下载引擎，使用合成 JSON 和进程替身覆盖服务契约。
