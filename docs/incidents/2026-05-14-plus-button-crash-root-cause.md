# macOS 14 点击「+」闪退根因分析

## 1. 背景

- 上游 `lizhelang/codexbar` 收到两条点击菜单栏「+」闪退反馈：
  - <https://github.com/lizhelang/codexbar/issues/26>
  - <https://github.com/lizhelang/codexbar/issues/28>（评论附带崩溃报告：[codexbar-2026-05-13-151115.txt](https://github.com/user-attachments/files/27696919/codexbar-2026-05-13-151115.txt)）
- 本仓库在 <https://github.com/Drswith/codexpanel/issues/1> 跟踪同类问题，并通过 PR <https://github.com/Drswith/codexpanel/pull/2>（提交 `36eba85`）尝试修复：把 `DetachedWindowPresenter.show` 的新建窗口流程推迟一轮 main runloop，并在 `orderFront` 之后再补一次 `applyStandardWindowConfiguration`。该修复随 1.4.2 发布。
- 用户在 <https://github.com/Drswith/codexpanel/issues/3> 反馈 Codex Panel **1.4.2 (202605140005)** 仍会在 macOS 14.2.1 点「+」后立即闪退，附新的崩溃报告：[Codex.Panel-2026-05-14-105549.txt](https://github.com/user-attachments/files/27740024/Codex.Panel-2026-05-14-105549.txt)。

本文基于以下两份崩溃报告（随 GitHub issue 附件提供，**不纳入本仓库版本管理**；PR 或文档中请使用下列链接，勿写本地或仓库内物理路径）：

- [codexbar-2026-05-13-151115.txt](https://github.com/user-attachments/files/27696919/codexbar-2026-05-13-151115.txt)（[codexbar#28](https://github.com/lizhelang/codexbar/issues/28) 评论附件）
- [Codex.Panel-2026-05-14-105549.txt](https://github.com/user-attachments/files/27740024/Codex.Panel-2026-05-14-105549.txt)（[Drswith/codexpanel#3](https://github.com/Drswith/codexpanel/issues/3) 附件）

## 2. 材料与符号化条件

| 材料 | 内容 |
| --- | --- |
| 1.4.2 崩溃报告 | [Codex.Panel-2026-05-14-105549.txt](https://github.com/user-attachments/files/27740024/Codex.Panel-2026-05-14-105549.txt)（[#3](https://github.com/Drswith/codexpanel/issues/3) 附件），进程 `com.codexpanel` 1.4.2 (202605140005)，macOS 14.2.1 (23C71)，arm64 |
| 上游崩溃报告 | [codexbar-2026-05-13-151115.txt](https://github.com/user-attachments/files/27696919/codexbar-2026-05-13-151115.txt)（[codexbar#28](https://github.com/lizhelang/codexbar/issues/28) 评论附件），进程 `lzhl.codexAppBar` 1.2.2，macOS 14.2.1，arm64 |
| 对照用 `Codex Panel.debug.dylib` | 任意读者在**自己环境**里用与仓库 `HEAD` 对应的 **Debug** 构建产物（通常位于 Xcode 构建生成的 `.app` 包内 `Contents/MacOS/`；**勿在 issue / PR 中粘贴个人电脑上的绝对路径**）。下文 `nm` / `dwarfdump` 示例里将该文件记为 `<CodexPanel.debug.dylib>`，由各人自行替换为本地路径。 |
| 崩溃报告中标的 1.4.2 dylib UUID | `b4e56a04-f268-3712-b74b-08d95667b5bb`（来自 [#3](https://github.com/Drswith/codexpanel/issues/3) 附件崩溃报告） |

对照构建产物的 UUID 与上述 1.4.2 报告中的 dylib UUID **通常不一致**。`git diff b4b5ab4..HEAD -- codexPanel/Views/MenuBarView.swift codexPanel/Services/DetachedWindowPresenter.swift codexPanel/Services/TokenStore.swift` 显示 1.4.2 → HEAD 之间，**`AddProviderSheet` / `OpenRouterModelPickerSection` / `OpenRouterModelCatalogSnapshot` / `openAddProviderWindow` / 建窗时序代码完全未动**；其间较新 tag 主要增加 a11y identifier、CLI 模块与测试等，**不改变**上述 view 相关源码与 mangled name 结论。

由此：

- **可以**用读者本地的对照构建 `Codex Panel.debug.dylib` 核对「这些类型与 mangled name 存在与否、字段长什么样、闭包是否被埋进 body」。这些都是编译期产物。
- **不能**用「较新对照构建」的 dylib 把 1.4.2 崩溃报告里 `0x101d84000 + 3712608` 这种「base + offset」直接 `atos` 反推回符号——较新构建相对 1.4.2 往往多出一批符号与段布局，偏移不可迁移。

下文凡涉及具体偏移 / frame 1 函数名，都按「不直接 atos」处理，结论只用 mangled name 等可跨版本验证的编译期产物作硬证据。

## 3. 结论

这不是 API key、provider 写入、OpenRouter 网络请求或 Codex 配置写盘导致的崩溃。**两次崩溃都发生在用户点「+」之后、`AddProviderSheet` 完成首帧布局之前**，由 SwiftUI / AttributeGraph 在后台 utility-qos 队列预热「类型布局描述符」（layout descriptor）时解析嵌套泛型 mangled name 失败、跳到空地址引起。

更精确地说：

- `AddProviderSheet.body.getter` 的具体 opaque 类型在编译期被 mangle 成一棵巨大的 `TupleView`，其中 `_ConditionalContent` 同时携带 Custom 与 OpenRouter 两个分支；这棵类型还嵌入了 `(String) async throws -> OpenRouterModelCatalogSnapshot` 闭包字面量。
- 当 SwiftUI 第一次见到 `AddProviderSheet` 时，AttributeGraph 会在 `com.apple.root.utility-qos` 队列上 `drain` 自己的 `TypeDescriptorCache`，对这棵类型走 `make_layout`，递归 `visit_field` → `mangled_type_name_ref` → `swift_getTypeByMangledNameInContextImpl`。
- 在 macOS 14.2.1 + SwiftUI 5.2.12 + AttributeGraph 5.0.77 上，runtime 这一步会拿到一个空的下一跳函数指针（`pc=0x0`、`esr=0x82000006 Instruction Abort Translation fault`），程序立即崩溃。

`36eba85` 把建窗推迟一轮 main runloop，**只是把崩溃点从「点 + 的同栈」后移到「main async 工作项里」**，view 类型自身没有变化，AttributeGraph 后台扫描必然按同形态复现，因此**不能视为根治方案**。

## 4. 崩溃证据

### 4.1 两份报告的同源形态

| 维度 | codexbar 1.2.2（Thread 15） | Codex Panel 1.4.2（Thread 25） |
| --- | --- | --- |
| Exception Type | `EXC_BAD_ACCESS (SIGSEGV)` | 同 |
| Exception Codes | `KERN_INVALID_ADDRESS at 0x0` | 同 |
| Termination | `Segmentation fault: 11` | 同 |
| 崩溃线程派发队列 | `com.apple.root.utility-qos` | 同 |
| 崩溃线程 ARM 状态 | `pc=0x0`, `esr=0x82000006 (Instruction Abort) Translation fault` | 同 |
| 栈底 | `AG::TypeDescriptorCache::drain_queue(void*)` | 同 |
| 中段路径 | `drain_queue → make_layout → visit_field → mangled_type_name_ref → swift_getTypeByMangledNameInContextImpl` 递归近 30 层 | 同（≈74 帧） |
| 栈顶是否落入应用 dylib | 否，最后一个非系统帧是 `swift_getTypeByMangledNodeImpl` | 是，frame 1 落在 `Codex Panel.debug.dylib + 3712608`（编译器生成的某个泛型替换 / 类型访问 callback） |
| 主线程是否经过 `DispatchQueue.main.async` | 否 | 是 |
| `AddProviderSheet.body.getter` 是否在主线程栈中 | 上游栈被截断，但主线程命中 `DetachedWindowPresenter.show` 与 `MenuBarView.menuFooter` 相关 closure | **是，明确出现** |

两次崩溃在「异常类型 + 崩溃线程派发队列 + AttributeGraph 后台扫描路径 + PC=0 形态」这四件事上完全一致，应视为同一类问题。差异恰好对应 PR #2 的时序变更。

### 4.2 主线程入口（Codex Panel 1.4.2）

```text
Thread 0::  Dispatch queue: com.apple.main-thread
…
11  Codex Panel.debug.dylib  __swift_instantiateConcreteTypeFromMangledNameV2 + 108
12  Codex Panel.debug.dylib  AddProviderSheet.body.getter + 384
13  Codex Panel.debug.dylib  protocol witness for View.body.getter in conformance AddProviderSheet + 12
14…55  SwiftUI / AttributeGraph     <view body 取值与首帧布局>
56  AppKit                   +[NSAnimationContext runAnimationGroup:]
…
70  AppKit                   +[NSWindow _windowWithContentViewController:styleMask:]
71  Codex Panel.debug.dylib  @nonobjc NSWindow.__allocating_init(contentViewController:) + 40
72  Codex Panel.debug.dylib  DetachedWindowPresenter.presentDetachedWindow(id:title:size:configuration:rootView:) + 2156
73  Codex Panel.debug.dylib  closure #1 in DetachedWindowPresenter.show<A>(…) + 1900
74  Codex Panel.debug.dylib  partial apply for closure #1 in DetachedWindowPresenter.show<A>(…)
75  Codex Panel.debug.dylib  thunk for @escaping @callee_guaranteed () -> ()
76  libdispatch.dylib        _dispatch_block_async_invoke2
77  libdispatch.dylib        _dispatch_client_callout
78  libdispatch.dylib        _dispatch_main_queue_drain
79  libdispatch.dylib        _dispatch_main_queue_callback_4CF
80  CoreFoundation           __CFRUNLOOP_IS_SERVICING_THE_MAIN_DISPATCH_QUEUE__
```

可以直接读出：

- PR #2 的 `DispatchQueue.main.async` 推迟生效——建窗工作项是从 `_dispatch_main_queue_drain` 调度而来，不再与 `NSStatusItem` 菜单关闭回调同栈。
- 这条工作项里 `NSWindow.__allocating_init(contentViewController:)` 仍会立刻让 AppKit 触发首帧 layout，从而进入 `AddProviderSheet.body.getter`，再调用 `__swift_instantiateConcreteTypeFromMangledNameV2`——Swift runtime 此刻为 `AddProviderSheet.body` 的 return type 实例化具体类型元数据。

### 4.3 崩溃线程（Codex Panel 1.4.2 Thread 25）

```text
Thread 25 Crashed::  Dispatch queue: com.apple.root.utility-qos
0   ???                       0x0
1   Codex Panel.debug.dylib   0x101d84000 + 3712608     ← 应用内某个泛型替换 / 类型访问器（无匹配 dSYM，未精确符号化）
2   libswiftCore.dylib        swift_getTypeByMangledNodeImpl + 60
3   libswiftCore.dylib        swift_getTypeByMangledNode + 836
4   libswiftCore.dylib        swift_getTypeByMangledNameImpl + 1172
5   libswiftCore.dylib        swift_getTypeByMangledName + 836
6   libswiftCore.dylib        swift_getTypeByMangledNameInContextImpl + 172
7   AttributeGraph            AG::swift::metadata::mangled_type_name_ref + 212
8   AttributeGraph            AG::swift::metadata_visitor::visit_field + 80
9…73 AttributeGraph            AG::swift::metadata::visit / AG::LayoutDescriptor::make_layout / TypeDescriptorCache::fetch（递归近 30 层）
74  AttributeGraph            AG::(anonymous namespace)::TypeDescriptorCache::drain_queue(void*) + 360
75  libdispatch.dylib         _dispatch_client_callout
76  libdispatch.dylib         _dispatch_root_queue_drain
77  libdispatch.dylib         _dispatch_worker_thread2
```

- frame 0 是 `0x0`；frame 1 内部计算的下一跳函数指针为空。
- 寄存器 `x0 = 0x00000000a5000001`、`x8 = 0x00000000a5000001` 形如「被压缩的类型元数据指针」（低 32 位 + 高位 tag），结合 SwiftUI 5.2 实现，这一般对应正在被解析的 mangled type name 节点。
- 整个栈反复递进 `visit_field → mangled_type_name_ref → swift_getTypeByMangledNameInContextImpl`，与 SwiftUI 为「带泛型字段的 View struct」生成 layout descriptor 时的行为完全一致。

> 注：要把 frame 1 精确符号化为「OpenRouterModelPickerSection 的某个具体生成器」需要与 1.4.2 build **完全匹配**的 dSYM；本仓库未必保留该 UUID 的符号包。读者手头的对照构建与崩溃报告中的 dylib UUID 又往往不同，故下文「具体可疑字段」属于源码侧合理推断，不做超出证据的强断言。

### 4.4 用对照构建 `Codex Panel.debug.dylib` 做的可重复 mangled name 复核

下面所有 mangled name 均来自对 **`<CodexPanel.debug.dylib>`**（见 §2 材料表；各人本地路径不同，此处不展开）执行 `nm -arch arm64` 的输出，经 `xcrun swift-demangle` 解出。这些是编译产物，与运行时崩溃地址无关；在「1.4.2 → 当前 HEAD 未改动 `AddProviderSheet` 等相关源码」的前提下，**与 1.4.2 崩溃报告对照的结论可迁移**（§2 已用 `git diff` 论证）。

#### A. `AddProviderSheet.body.getter` 的具体 opaque 类型

```text
_$s11Codex_Panel16AddProviderSheet…LLV4bodyQrvg7SwiftUI9TupleViewVyAF4TextV_…
AF19_ConditionalContentVyAHyAF11SecureFieldVyAJG_AA015OpenRouterModelV7SectionACLLVtG
AHyAF0S5FieldVyAJG_A12_A12_A6_tGGAF6HStackVyAHyAF6SpacerV_AF6ButtonVyAJG…
```

demangle 后：

```text
Codex_Panel.(AddProviderSheet in _639C4FD…).body.getter : some
SwiftUI.TupleView<(
    SwiftUI.Text,
    <<opaque return type of (extension in SwiftUI):SwiftUI.View.pickerStyle<A where A1: SwiftUI.PickerStyle>(A1) -> some>>.0,
    SwiftUI._ConditionalContent<
        SwiftUI.TupleView<(
            SwiftUI.SecureField<SwiftUI.Text>,
            Codex_Panel.(OpenRouterModelPickerSection in _639C4FD…)
        )>,
        SwiftUI.TupleView<(
            SwiftUI.TextField<SwiftUI.Text>,
            SwiftUI.TextField<SwiftUI.Text>,
            SwiftUI.TextField<SwiftUI.Text>,
            SwiftUI.SecureField<SwiftUI.Text>
        )>
    >,
    SwiftUI.HStack<SwiftUI.TupleView<(
        SwiftUI.Spacer,
        SwiftUI.Button<SwiftUI.Text>,
        <<opaque return type of (extension in SwiftUI):SwiftUI.View.disabled(Swift.Bool) -> some>>.0
    )>>
)>
```

关键事实：

- `_ConditionalContent<X, Y>` 的两个分支**同时**被 mangle 进 `body.getter` 的具体类型，与运行时 `isOpenRouter` 是 `true` 还是 `false` 无关；任何对 `AddProviderSheet` 视图的 layout descriptor 扫描都必然递归访问 `OpenRouterModelPickerSection`。
- `<<opaque return type of pickerStyle>>` / `<<opaque return type of disabled>>` 这些 SwiftUI extension 的 opaque 返回类型也被纳入，构成额外的 mangled name 解析点。

#### B. body 内嵌的 OpenRouter refresh 异步闭包

```text
closure #2 (Swift.String) async throws -> Codex_Panel.OpenRouterModelCatalogSnapshot
    in closure #1 () -> SwiftUI.TupleView<(SwiftUI.Text, <<opaque pickerStyle.0>>,
        SwiftUI._ConditionalContent<…OpenRouterModelPickerSection…>, …)>
    in Codex_Panel.(AddProviderSheet in _639C4FD…).body.getter : some
```

同时伴随 Swift 5.9 为 async closure 自动生成的标准辅助符号：`partial apply forwarder`、`suspend resume partial function`、`await resume partial function`。

这就**直接证实**：

```swift
refreshAction: { apiKey in
    try await self.store.previewOpenRouterModelCatalog(apiKey: apiKey)
}
```

被 mangle 到 `AddProviderSheet.body.getter` 的子作用域里，闭包返回类型 `OpenRouterModelCatalogSnapshot` 进入了 `body` 的元数据图。

而 `OpenRouterModelCatalogSnapshot` 本身（`codexPanel/Services/TokenStore.swift` 第 54 行）：

```swift
struct OpenRouterModelCatalogSnapshot: Equatable {
    var models: [CodexPanelOpenRouterModel]
    var fetchedAt: Date
}
```

也存在独立 metadata 入口 `Codex_Panel.OpenRouterModelCatalogSnapshot`。

#### C. 同款模式重复出现

dylib 中还能解出：

```text
closure #1 (Swift.String) async throws -> OpenRouterModelCatalogSnapshot
    in closure #1 () -> SwiftUI.TupleView<(…OpenRouterModelPickerSection…)>
    in Codex_Panel.(AddOpenRouterAccountSheet in _639C4FD…).body.getter : some

closure #1 (Swift.String) async throws -> OpenRouterModelCatalogSnapshot
    in closure #1 () -> SwiftUI.TupleView<(…OpenRouterModelPickerSection…)>
    in Codex_Panel.(EditOpenRouterModelSheet in _639C4FD…).body.getter : some
```

说明「view 静态类型直接持有 `(String) async throws -> 业务结构体` 函数字段 + 嵌套 `OpenRouterModelPickerSection`」是仓库中重复出现的模式，至少有三个 sheet 都触碰这条结构：`AddProviderSheet`、`AddOpenRouterAccountSheet`、`EditOpenRouterModelSheet`。这对修复方案的复用性有影响。

## 5. 受影响代码路径

点击菜单栏「+」之后的调用链（见 `codexPanel/Views/MenuBarView.swift`、`codexPanel/Services/DetachedWindowPresenter.swift`）：

1. `MenuBarView` 工具条按钮 `plus.circle` 触发 `openAddProviderWindow(defaultPreset:)`。
2. `requestCloseStatusItemMenu()` 关闭菜单后，调用 `DetachedWindowPresenter.shared.show(id: "add-provider", title: "Add Provider", size: 520×620) { AddProviderSheet(…) }`。
3. PR #2 后的 `show`：若窗口尚未存在，则把 `AnyView(content())` 与 `presentDetachedWindow` 调用塞进 `DispatchQueue.main.async`，避免在菜单 action 同栈建窗。
4. 工作项被 main runloop 调度后，`presentDetachedWindow` 创建 `NSHostingController(rootView: AnyView)` 和 `NSWindow(contentViewController:)`。
5. AppKit 立刻为新窗口跑一次 `layoutSubtreeIfNeeded`，触发 `AddProviderSheet.body` 取值与类型元数据实例化。
6. 与此同时，AttributeGraph 在后台 utility-qos 队列上 `drain` 自己的 `TypeDescriptorCache`，对刚见到的 view 类型走 `make_layout`，递归 visit_field 并通过 `swift_getTypeByMangledNameInContext` 解析嵌套泛型。**这一步在 macOS 14.2.1 上跳到 `0x0`。**

`AddProviderSheet.body` 的关键结构（`codexPanel/Views/MenuBarView.swift` 第 2374 行起）：

```swift
var body: some View {
    VStack(alignment: .leading, spacing: 12) {
        Text("Add Provider").font(.headline)

        Picker("Preset", selection: $preset) {
            ForEach(AddProviderPreset.allCases) { preset in
                Text(preset.title).tag(preset)
            }
        }
        .pickerStyle(.segmented)

        if isOpenRouter {
            SecureField("API key", text: $apiKey)
            OpenRouterModelPickerSection(
                store: self.store,
                apiKey: $apiKey,
                selectedModelIDs: $openRouterSelectedModelIDs,
                manualModelID: $openRouterManualModelID,
                cachedModels: $openRouterCachedModels,
                fetchedAt: $openRouterFetchedAt,
                refreshAction: { apiKey in
                    try await self.store.previewOpenRouterModelCatalog(apiKey: apiKey)
                },
                helperText: "…"
            )
        } else {
            TextField("Provider name", text: $label)
            TextField("Base URL", text: $baseURL)
            TextField("Account label", text: $accountLabel)
            SecureField("API key", text: $apiKey)
        }

        HStack { …Cancel / Save button… }
    }
    .padding(16)
    .frame(width: self.isOpenRouter ? 460 : 360)
    .onChange(of: preset) { … }
}
```

`OpenRouterModelPickerSection` 内部（`codexPanel/Views/MenuBarView.swift` 第 2167-2310 行）：

- `@ObservedObject var store: TokenStore`
- 6 个 `@Binding`（`apiKey: String`、`selectedModelIDs: Set<String>`、`manualModelID: String`、`cachedModels: [CodexPanelOpenRouterModel]`、`fetchedAt: Date?`、`apiKey: String`）
- `let refreshAction: (String) async throws -> OpenRouterModelCatalogSnapshot`
- `let helperText: String`
- 3 个 `@State`
- body 内有 `List { ForEach { Toggle { VStack { Text, Text } } } }`

综合 §4.4 的 mangled name 与上述源码，**AttributeGraph 在后台 utility 队列扫描的就是 `AddProviderSheet` 这棵 view 类型树**；问题不在某条业务逻辑写错，而在 view 类型本身复杂度过高、且使用了 `(…) async throws -> 自定义结构体` 这类 macOS 14 上 AttributeGraph 处理脆弱的字段类型。

## 6. 根因解释

把直接事实和编译产物拼起来：

1. **触发条件**：在 macOS 14.2.1 上首次让 SwiftUI 见到 `AddProviderSheet` 这棵 view 类型。由 `presentDetachedWindow` 内 `NSHostingController(rootView: AnyView(AddProviderSheet(…)))` + `NSWindow.__allocating_init(contentViewController:)` 自动触发首帧布局，进而调用 `AddProviderSheet.body.getter`。
2. **类型膨胀**：`body.getter` 的 concrete opaque 类型是 §4.4.A 那棵巨大的 `TupleView<( …, _ConditionalContent<…OpenRouterModelPickerSection…>, HStack<…> )>`，同时身上挂着 §4.4.B 的 `(String) async throws -> OpenRouterModelCatalogSnapshot` 闭包字面量。
3. **后台扫描**：SwiftUI / AttributeGraph 5.0.77 在主线程发起首帧布局时，会异步在 `com.apple.root.utility-qos` 队列上跑 `TypeDescriptorCache::drain_queue`，对这棵新见到的 view 类型 + 它引用的所有字段类型，依次调用 `make_layout → visit_field → mangled_type_name_ref → swift_getTypeByMangledNameInContextImpl`。
4. **崩溃点**：在解某个嵌套 mangled name 时，runtime 拿到的下一跳函数指针为空（`pc=0x0`、`Instruction Abort Translation fault`），Swift runtime 与 AttributeGraph 都不做防护，`blr` 跳过去就崩。这是 macOS 14.2.1 SwiftUI 5.2.12 + Swift 5.9 runtime 的一个已知形态：在 `swift_getTypeByMangledNameInContextImpl` 提供给 `swift_getTypeByMangledNode` 的 substitutions 回调返回空时，没有 nil 检查。
5. **为什么是这棵 view**：`_ConditionalContent` 同时携带两个分支、`OpenRouterModelPickerSection` 内部带 6 个 `@Binding` + `@ObservedObject` + 两层 SwiftUI extension opaque return type + 一个 `(String) async throws -> ConcreteStruct` 函数字段；元数据图深度 + 自定义结构体引用 + `_ConditionalContent` + opaque return type 这几样合起来，落在了 Apple runtime 的脆弱点上。两次崩溃栈都 ≥70 层递归 `visit_field`，说明 view 类型自身已经把扫描深度推到了高位。

> 保守提示：从崩溃报告本身无法 100% 锁定「是 `OpenRouterModelPickerSection` 的哪个具体字段」让 runtime 返回了 nil；但能从 mangled name 直接验证「这棵 view 类型确实包含 `OpenRouterModelCatalogSnapshot` 异步闭包 + 完整 OpenRouter 子树」，并且崩溃栈的形态与「巨型 TupleView + `_ConditionalContent` + 自定义结构体函数字段」这一类典型样本完全吻合。这构成了「**消除 OpenRouter 子树就能消除崩溃**」这个修复方向的高置信依据。

## 7. 为什么 PR #2 / `36eba85` 不充分

PR #2 实现要点（`codexPanel/Services/DetachedWindowPresenter.swift`）：

- 标 `@MainActor`，统一窗口字典的访问 actor 语义。
- 新建窗口走 `DispatchQueue.main.async(execute: workItem)`，并维护 `pendingDetachedWindowPresentations` / `pendingDetachedWindowPresentationTokens` 支持 cancel；只有「窗口不存在」的分支异步，「复用窗口」分支仍同步替换 `rootView`。
- `orderFront` 之后再次 `applyStandardWindowConfiguration`，并加一个 `DispatchQueue.main.async` 尾应用，稳住 `contentMinSize` 首帧抖动。

针对的问题：

- 解决「点击 + 时 NSStatusItem 菜单关闭回调与 NSWindow 建窗同栈」这一时序竞态。
- 1.4.2 新崩溃报告主线程显示 `_dispatch_main_queue_drain → DetachedWindowPresenter.presentDetachedWindow`，确认这层异步保护实际生效。

为什么不解决根因：

- 触发 `AttributeGraph::TypeDescriptorCache::drain_queue` 后台扫描的事件，是 SwiftUI **首次见到 `AddProviderSheet` 这棵 view 类型**。无论建窗工作项是从菜单 action 同栈，还是延迟一轮 main runloop 才跑，都会产生同一次扫描；扫描进到 OpenRouter 子树的脆弱点后崩溃必现。
- view 静态类型由编译期决定，PR #2 没有动过 `AddProviderSheet` / `OpenRouterModelPickerSection` / `body`，因此 §4.4 mangled name 树完全没变。

结论：PR #2 是**有效的卫生改进**（菜单 + SwiftUI 异步建窗是合理做法），但**不应作为本 issue 的根治方案**；后续修复不要回滚它，但要在此基础上再做 view 结构层面的处理。Commit message / changelog 里也应明确这层只是「降低同栈竞态概率」，不是「修复点 + 闪退根因」，避免再次错误归因。

## 8. 已排除或低概率方向

- 不是 token 泄漏、`auth.json` / `config.toml` 损坏：崩溃发生在「+」点击后立即出现，未进入 `onSave` / `previewOpenRouterModelCatalog` 网络逻辑。
- 不是 `OpenRouterModelCatalogService.fetchCatalog` 网络错误：用户尚未输入 API key，更未点 Refresh。
- 不是 `DetachedWindowPresenter` 复用窗口或 `contentMinSize` 问题：主线程栈走的是 `presentDetachedWindow` 的「新建窗口」分支（`NSWindow.__allocating_init`）。
- 不是仅上游 codexbar 才会出现：Codex Panel 1.4.2 主线程符号化日志已显式命中本仓库 `AddProviderSheet.body.getter` 与 `DetachedWindowPresenter.presentDetachedWindow`。
- 不是 PR #2 写错：异步推迟与额外 `applyStandardWindowConfiguration` 都正确生效，只是不解决根因。

## 9. 建议修复方向

目标：**降低首次显示 `AddProviderSheet` 时暴露给 SwiftUI / AttributeGraph 的静态 view 类型复杂度**，让 macOS 14.2.1 上的 type metadata cache 没机会落到 PC=0 的脆弱路径。按优先级排序：

### 9.1 本次已落地修复

当前仓库已按上述方向落地一版最小结构修复，对应 `codexPanel/Views/MenuBarView.swift`：

1. **把 `OpenRouterModelPickerSection.refreshAction` async 闭包字段改成轻量 `refreshMode` 枚举**。

   `refreshModels()` 改为直接通过 `store.previewOpenRouterModelCatalog(apiKey:)` 或 `store.refreshOpenRouterModelCatalog()` 分支执行刷新，不再把 `(String) async throws -> OpenRouterModelCatalogSnapshot` 作为 view 字段传入。

   这样 `AddProviderSheet`、`AddOpenRouterAccountSheet`、`EditOpenRouterModelSheet` 三处 body 类型里都不再内嵌「async throws 返回业务结构体」的函数节点。

2. **在 `AddProviderSheet` 的 preset 分支边界做 `AnyView` 擦除**。

   当前 `body` 不再直接持有：

   ```swift
   if isOpenRouter { ... } else { ... }
   ```

   而是改成：

   ```swift
   private var providerFormContent: AnyView {
       self.isOpenRouter ? self.openRouterProviderFormContent : self.customProviderFormContent
   }
   ```

   `body` 内只引用一个 `SwiftUI.AnyView` 槽位。对照本地 Debug 构建的 `swift-demangle` 输出，`AddProviderSheet.body.getter` 现已从修复前的 `_ConditionalContent<OpenRouter 分支, Custom 分支>` 收敛为 `TupleView<(Text, Picker 样式 opaque, SwiftUI.AnyView, HStack<...>)>`，默认点「+」时不再把 OpenRouter 子树挂进首帧 `body` 元数据。

3. **同步把相同模式从另外两个 OpenRouter sheet 上移除**。

   `AddOpenRouterAccountSheet` 与 `EditOpenRouterModelSheet` 仍然会渲染 `OpenRouterModelPickerSection`，但它们现在只携带 `refreshMode`，不再携带 async 闭包字段，避免后续在同一系统版本上撞回相同的元数据脆弱点。

这版修复保留了 PR #2 的异步建窗卫生改动，只额外收敛 view 静态类型，不回退已生效的窗口时序保护。

如果 macOS 14.2.1 实机回归后仍有残留风险，可继续考虑以下强化项：

1. **把默认进入路径变成「先选 preset，再渲染对应表单」**。

    让 `openAddProviderWindow(defaultPreset: .custom)` 首屏只渲染一个 `AddProviderPresetPickerView`（轻量 Picker + 提示），用户主动选 OpenRouter 时再 push / replace 到 OpenRouter 表单。即使后续 OpenRouter 子树仍有 SwiftUI 14.2.1 风险，影响范围也从「点 + 立即崩」收敛到「主动选 OpenRouter 才触发」，可叠加 try/catch、降级表单等更精细的处理。

2. **（可选 / 低成本）**用 `task { … }` 替代部分 view 体内的 `Task { … }`，把首帧繁重 `List` / `ForEach` 容器的实际创建推迟一帧；同时考虑用 `LazyVStack` 等容器替换部分 `List`。属于 macOS 14 SwiftUI 元数据竞态的通用 workaround，价值偏低但成本也低。

不建议的方向：

- 把 PR #2 改成 `DispatchQueue.main.asyncAfter(deadline: .now() + 0.1)`、`.now() + 0.3` 等延时调参——已知 1.4.2 失败例已经走完 main async 工作项还是崩，延迟更长只会让用户感知更卡。
- 把 `AddProviderSheet` 包成更深层的 `NavigationStack` 或 `Sheet`——会再次膨胀 view 类型而不是收敛。

## 10. 建议验证

修复构建发布前后，做对照实验：

- **环境**：macOS 14.2.1 (23C71)，arm64，Codex Panel 修复 build。
- **复现路径**：菜单栏点 **+**，分别用默认 Custom 与切换到 OpenRouter 两个 preset 各做 10 次，覆盖以下场景：
  - 冷启动后第一次点 +；
  - 关闭添加窗口后立即再次点 +（走 `DetachedWindowPresenter` 复用窗口分支）；
  - 在 OpenRouter 表单输入 API key 并点 Refresh Models；
  - 在 Custom 表单保存 provider；
  - 在 OpenRouter 表单勾选 models 并保存。
- **判定信号**：观察是否再生成崩溃报告；如果有，重点比对崩溃线程栈是否仍含：
  - `AG::(anonymous namespace)::TypeDescriptorCache::drain_queue(void*)`
  - `swift_getTypeByMangledNameInContextImpl`
  - `AG::LayoutDescriptor::make_layout`
- **主线程是否仍命中**：
  - `AddProviderSheet.body.getter`
  - `OpenRouterModelPickerSection.body.getter`
- **回归测试**：保留现有 `DetachedWindowPresenterTests`，再补一个针对 `AddProviderSheet` 拆分后首帧构造的最小回归测试，至少覆盖：
  - 默认 `.custom` 路径首帧能完整渲染，不抛 SwiftUI 类型实例化异常；
  - 切到 OpenRouter 后再切回 Custom，view 树不残留 OpenRouter 子树；
  - `DetachedWindowPresenter.show` 异步建窗后窗口尺寸、`contentMinSize` 与 PR #2 测试一致。

修复成功的标志：上述符号一项都不再出现，且 10 次以上压测稳定。若仅 `OpenRouterModelPickerSection.body.getter` 仍出现，说明范围已收敛到 OpenRouter 表单本身，可继续做建议 3 的字段类型收敛。

> 提示：XCTest 在开发机系统版本上不一定能直接复现 macOS 14.2.1 runtime 的崩溃形态；回归测试主要用于「固定拆分后的 view 结构与默认路径」，崩溃本身仍需要在 macOS 14.2.1 实机回归。

## 11. 不确定点与置信度

| 命题 | 置信度 | 说明 |
| --- | --- | --- |
| 两次崩溃同源（同一类 SwiftUI / AttributeGraph runtime 行为） | 高 | 两份报告异常码、地址、派发队列、栈底完全一致，且二者主线程行为差异恰好对应 PR #2 的时序变更 |
| 触发点是 `AddProviderSheet` 首帧 view 类型实例化 | 高 | 1.4.2 主线程栈直接命中 `AddProviderSheet.body.getter + __swift_instantiateConcreteTypeFromMangledNameV2` |
| `body` 静态类型确实包含完整 OpenRouter 子树 + `OpenRouterModelCatalogSnapshot` async closure | 高 | 由 dylib mangled name + `swift-demangle` 直接验证，与运行时 `isOpenRouter` 无关 |
| PR #2 / `36eba85` 没有改动 view 静态类型，因此不可能根治 | 高 | `git diff` 直接显示 PR #2 只改 `DetachedWindowPresenter`，不动 view 文件 |
| AttributeGraph 在 utility QoS 队列预热 layout descriptor，并在解嵌套 mangled name 时崩到 `0x0` | 高 | 两份报告崩溃线程栈结构完全吻合该路径 |
| 「精确到哪个字段」导致 runtime 返回 nil 类型指针 | 中 | 报告未提供能直接指向具体字段的额外信息；只能说 OpenRouter 子树 + `OpenRouterModelCatalogSnapshot` 是与该类形态最匹配的可疑点 |
| 「拆分 view + 分支边界 AnyView」能消除崩溃 | 中高 | 与已知 SwiftUI 14 大型 view 类型 workaround 经验一致，需要 macOS 14.2.1 实机验证 |
| 是否还要做建议 3（移除 async closure 字段） | 中 | 视建议 1 实机效果而定；若只做拆分仍偶现，再加上建议 3 |
| 这是 macOS 14.2.1 SwiftUI / AttributeGraph runtime 脆弱点 | 中 | 客户端无法直接修 Apple runtime，但可以通过拆分和类型隔离规避触发 |

## 12. 附录

### 12.1 关键 mangled name 与 demangled 结果

**A. `AddProviderSheet.body.getter` opaque 具体类型**

```text
_$s11Codex_Panel16AddProviderSheet33_639C4FD79DE66C9F84CE8D483659EB56LLV4bodyQrvg
7SwiftUI9TupleViewVyAF4TextV_AF0R0PAFE11pickerStyleyQrqd__AF06PickerU0Rd__lFQOy
AF0V0VyAjA0cD6PresetACLLOAF7ForEachVySayARGSSAlFE3tag_15includeOptionalQrqd___
SbtSHRd__lFQOyAJ_ARQo_GG_AF09SegmentedvU0VQo_AF19_ConditionalContentVyAHy
AF11SecureFieldVyAJG_AA015OpenRouterModelV7SectionACLLVtGAHyAF0S5FieldVyAJG_
A12_A12_A6_tGGAF6HStackVyAHyAF6SpacerV_AF6ButtonVyAJGAlFE8disabledyQrSbF
QOyAlFE06buttonU0yQrqd__AF015PrimitiveButtonU0Rd__lFQOyA21__AF023BorderedProminentButtonU0VQo__Qo_tGGtG
```

→

```text
Codex_Panel.(AddProviderSheet in _639C4FD…).body.getter : some
SwiftUI.TupleView<(
    SwiftUI.Text,
    <<opaque pickerStyle.0>>,
    SwiftUI._ConditionalContent<
        SwiftUI.TupleView<(SwiftUI.SecureField<SwiftUI.Text>, Codex_Panel.OpenRouterModelPickerSection)>,
        SwiftUI.TupleView<(SwiftUI.TextField<SwiftUI.Text>, SwiftUI.TextField<SwiftUI.Text>, SwiftUI.TextField<SwiftUI.Text>, SwiftUI.SecureField<SwiftUI.Text>)>
    >,
    SwiftUI.HStack<SwiftUI.TupleView<(SwiftUI.Spacer, SwiftUI.Button<SwiftUI.Text>, <<opaque disabled.0>>)>>
)>
```

**B. body 内嵌的 OpenRouter refresh 闭包**

```text
closure #2 (Swift.String) async throws -> Codex_Panel.OpenRouterModelCatalogSnapshot
    in closure #1 () -> SwiftUI.TupleView<(SwiftUI.Text, <<opaque pickerStyle.0>>,
        _ConditionalContent<TupleView<(SecureField<Text>, OpenRouterModelPickerSection)>,
                            TupleView<(TextField<Text>, TextField<Text>, TextField<Text>, SecureField<Text>)>>,
        HStack<TupleView<(Spacer, Button<Text>, <<opaque disabled.0>>)>>)>
    in Codex_Panel.(AddProviderSheet in _639C4FD…).body.getter : some
```

并伴随 partial apply forwarder / suspend resume / await resume 三种 Swift async 标准辅助函数。

**C. 仓库内重复模式**

`AddOpenRouterAccountSheet.body.getter` 与 `EditOpenRouterModelSheet.body.getter` 也内嵌同款 `(String) async throws -> OpenRouterModelCatalogSnapshot` 闭包子节点，说明这种「view 持有 async throws 函数字段」是仓库中的重复模式，§9.3 的收敛应统一对这三处生效。

### 12.2 跨版本一致性校验

- `git diff b4b5ab4..HEAD -- codexPanel/Views/MenuBarView.swift codexPanel/Services/DetachedWindowPresenter.swift codexPanel/Services/TokenStore.swift`：在「+」点击相关链路与 `OpenRouterModel*` 类型上为空（PR #2 之外只是 `DetachedWindowPresenter` 新增 a11y identifier，没改时序）。
- `nm -arch arm64 "<CodexPanel.debug.dylib>" | grep AddProviderSheet | wc -l`：在与 `HEAD` 对齐的一次本地对照构建上约为 545 个相关符号（各人构建可能略有差异，以本地 `nm` 输出为准）。
- `dwarfdump --uuid "<CodexPanel.debug.dylib>"`：对照构建的 arm64 UUID 与崩溃报告中 1.4.2 dylib 的 UUID（`b4e56a04-…-08d95667b5bb`）**不一致**为常态；因此本文不依赖 `atos` 对报告内「base + offset」做跨构建反推。

### 12.3 上游 codexbar 主线程符号补充

上游报告日志没有 Codex Panel 这份报告里完整的 app 符号，但崩溃形态、系统版本、触发动作、AttributeGraph 后台扫描栈和 utility queue 崩溃线程一致：

```text
NSWindow _windowWithContentViewController
specialized DetachedWindowPresenter.show(...)
closure #6 in closure #1 in MenuBarView.menuFooter.getter
```

二者应视为同一类问题。
