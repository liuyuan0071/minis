# Android 移动端工作助手 Agent 改造计划

## 一、概述

将 OpenMinis 的 Android 端改造为开箱即用的"移动端工作助手 Agent"，降低使用门槛。核心改动：
1. 默认接入 DeepSeek API（Key 从 `.env` 读取，用户不可见/不可复制）
2. 内置 4 个技能（PPT生成、周报生成、文章去AI味、海报设计师）
3. 更换 App 图标为新的 AI 工作助手图标
4. 配置 Gitee 云编译

---

## 二、当前状态分析

### 项目结构
- **Android 模块**: `src/android/` — Kotlin + Jetpack Compose + Material3
- **包名**: `com.openminis.app`
- **构建**: AGP 8.7.3, Kotlin 2.1.0, Gradle Kotlin DSL
- **API 层**: 统一 `LLMProvider` 接口，`ProviderFactory` 根据类型创建 Provider
- **DeepSeek 支持**: 已通过 `ProviderType.openAI` + `customBaseURL = "https://api.deepseek.com"` 实现（代码中有大量 DeepSeek 兼容处理）
- **Provider 配置持久化**: `ProviderRepository` + `EncryptedSharedPreferences`（API Key 已加密存储）
- **技能系统**: `SkillRepository` — 支持从 ZIP 导入、从 GitHub URL 导入、标记为 BUNDLED

### 关键文件
| 文件 | 用途 |
|------|------|
| `.env` | 根目录，含 `DEEPSEEK_API_KEY=sk-...` |
| `src/android/app/build.gradle.kts` | 构建配置，可读 `.env` 注入 BuildConfig |
| `MinisApp.kt` | Application 入口，初始化所有 Repository |
| `ProviderRepository.kt` | 管理 Provider 实例（增删改查 + API Key 加密存储） |
| `ProviderFactory.kt` | 根据 `ProviderInstance` 创建 LLM Provider |
| `ProviderConfig.kt` | `ProviderInstance`、`ProviderType` 等数据模型 |
| `SkillRepository.kt` | 技能管理，含 `importFromArchive()` 从 ZIP 导入 |
| `raw/` 目录 | 图标 + 4 个技能 ZIP 包 |

---

## 三、具体改动方案

### 任务 1：默认接入 DeepSeek API（Key 从 .env 读取，用户不可见）

#### 1.1 构建时读取 .env 注入 BuildConfig
**文件**: `src/android/app/build.gradle.kts`

在 `build.gradle.kts` 中添加读取 `.env` 文件的逻辑：
- 项目根目录的 `.env` 文件路径为 `rootProject.file("../../.env")`（相对于 `src/android/`）
- 读取 `DEEPSEEK_API_KEY` 值，注入 `BuildConfig.DEEPSEEK_API_KEY`

```kotlin
// 在 android { defaultConfig { ... } } 块内添加
val envFile = rootProject.file("../../.env")
val deepseekKey = if (envFile.exists()) {
    envFile.readLines()
        .firstOrNull { it.startsWith("DEEPSEEK_API_KEY=") }
        ?.substringAfter("=")
        ?.trim()
        ?: ""
} else ""
buildConfigField("String", "DEEPSEEK_API_KEY", "\"$deepseekKey\"")
```

#### 1.2 首次启动自动创建 DeepSeek Provider 实例
**文件**: `src/android/app/src/main/java/com/openminis/app/MiniskApp.kt`

在 `MinisApp.onCreate()` 中，初始化完 `providerRepository` 后，添加自动创建 DeepSeek Provider 的逻辑：

```kotlin
// 在 providerRepository 初始化之后，添加：
autoSetupDeepSeekProvider()
```

新增 `autoSetupDeepSeekProvider()` 方法：
- 检查 `BuildConfig.DEEPSEEK_API_KEY` 是否非空
- 检查 `providerRepository.instances` 中是否已存在指向 `api.deepseek.com` 的实例（避免重复创建）
- 如果不存在，创建一个新的 `ProviderInstance`：
  - `providerType = ProviderType.openAI`
  - `label = "DeepSeek"`
  - `customBaseURL = "https://api.deepseek.com"`
  - `credentialType = ProviderCredential.apiKey`
- 调用 `providerRepository.addInstance(instance)` 添加
- 调用 `providerRepository.saveApiKey(instance.id, BuildConfig.DEEPSEEK_API_KEY)` 保存 Key（已加密）

#### 1.3 禁止用户从 UI 查看/复制 DeepSeek Key
**文件**: `src/android/app/src/main/java/com/openminis/app/ui/settings/ProviderSettingsScreen.kt`（需确认路径）

需要修改 Provider 设置界面，对于指向 `api.deepseek.com` 的实例：
- 隐藏 "API Key" 显示字段（不展示 Key 内容）
- 隐藏 "复制 API Key" 按钮
- 保留 "更换 Provider" 和 "删除" 功能
- 显示提示文字："此 API Key 由系统管理，不可查看"

**实现方式**：在 Provider 设置界面的 ViewModel 或 Composable 中，检查 `instance.customBaseURL` 是否包含 `api.deepseek.com`，如果是则隐藏 API Key 相关 UI。

#### 1.4 安全加固
- `.env` 文件不会打包进 APK（通过 `build.gradle.kts` 在构建时读取值，不复制文件）
- API Key 通过 `EncryptedSharedPreferences` 加密存储
- Release 构建启用 ProGuard 混淆（已有配置）

---

### 任务 2：内置 4 个技能

#### 2.1 将技能 ZIP 包作为 assets 打包
**操作**: 将 `raw/` 目录下的 4 个 ZIP 文件复制到 Android 的 assets 目录：
- `raw/ppt生成.zip` → `src/android/app/src/main/assets/bundled-skills/ppt生成.zip`
- `raw/周报生成.zip` → `src/android/app/src/main/assets/bundled-skills/周报生成.zip`
- `raw/文章去AI味工具.zip` → `src/android/app/src/main/assets/bundled-skills/文章去AI味工具.zip`
- `raw/海报设计师.zip` → `src/android/app/src/main/assets/bundled-skills/海报设计师.zip`

#### 2.2 扩展 SkillRepository 的 installBundledSkills()
**文件**: `src/android/app/src/main/java/com/openminis/app/data/repository/SkillRepository.kt`

修改 `installBundledSkills()` 方法：
- 遍历 `assets/bundled-skills/` 目录下的所有 ZIP 文件
- 对每个 ZIP 文件调用 `importFromArchive(assetInputStream)`
- 使用 `ImportSource.BUNDLED` 标记
- 按 `skill-creator` 同样的模式处理版本检查和更新

```kotlin
private fun installBundledSkills() {
    // 保留原有的 skill-creator 安装逻辑
    installBundledSkillCreator()
    // 新增：安装内置技能包
    installBundledSkillPacks()
}

private fun installBundledSkillPacks() {
    try {
        val assetManager = context.assets
        val skillFiles = assetManager.list("bundled-skills") ?: return
        for (fileName in skillFiles) {
            if (!fileName.endsWith(".zip")) continue
            val skillId = fileName.removeSuffix(".zip")
            // 检查是否已安装且版本相同
            val existing = _skills.value.find { it.id == skillId }
            if (existing != null) continue // 已安装则跳过
            try {
                assetManager.open("bundled-skills/$fileName").use { inputStream ->
                    importFromArchive(inputStream)
                }
            } catch (e: Exception) {
                Log.w(TAG, "Failed to install bundled skill: $fileName - ${e.message}")
            }
        }
    } catch (e: Exception) {
        Log.w(TAG, "Failed to list bundled skills: ${e.message}")
    }
}
```

#### 2.3 构建配置：不压缩 assets 中的 ZIP
**文件**: `src/android/app/build.gradle.kts`

在 `androidResources` 块（已有 `noCompress` 配置）中，确认 ZIP 文件不会被压缩（保证读取正确性）：
```kotlin
androidResources {
    noCompress += listOf("tar.gz", "proot-aarch64", "zip")
}
```

---

### 任务 3：更换 App 图标

#### 3.1 生成各密度 PNG 图标
将 `raw/AI工作助手图标设计.png` 转换为 Android 标准 mipmap 图标：

| 密度 | 目录 | 尺寸 |
|------|------|------|
| mdpi | `mipmap-mdpi/` | 48×48 |
| hdpi | `mipmap-hdpi/` | 72×72 |
| xhdpi | `mipmap-xhdpi/` | 96×96 |
| xxhdpi | `mipmap-xxhdpi/` | 144×144 |
| xxxhdpi | `mipmap-xxxhdpi/` | 192×192 |

需要替换的文件（每个密度各 4 个文件）：
- `ic_launcher.png` — 传统图标（向后兼容）
- `ic_launcher_foreground.png` — 自适应图标前景
- `ic_launcher_foreground_light.png` — 浅色主题前景
- `ic_launcher_foreground_dark.png` — 深色主题前景

同时更新暗色模式（`mipmap-night-*`）的对应文件。

#### 3.2 更新自适应图标 XML
**文件**: `res/mipmap-anydpi-v26/ic_launcher.xml`

自适应图标使用 `@color/ic_launcher_background` 作为背景色（目前为 `#EFF2F6`），前景引用 `@mipmap/ic_launcher_foreground`。替换 PNG 后自动生效。

**可选**: 调整背景色以匹配新图标的主色调。

#### 3.3 更新 Monochrome 图标
**文件**: `res/drawable/ic_launcher_monochrome.xml`

Monochrome 图标用于 Android 13+ 主题图标。当前是一个 "M" 字母形状的矢量图。
需要重新设计为新图标的单色轮廓版本，或者简化处理——保留现有矢量（如果新图标也以 "M" 为主题）。

---

### 任务 4：Gitee 云编译 APK

#### 4.1 创建 Gitee 工作流配置
**文件**: `.gitee/workflows/build-android.yml`

创建一个 Gitee CI/CD 工作流：
- 触发条件：推送至 main 分支 或 手动触发
- 环境：Ubuntu + JDK 17 + Android SDK
- 步骤：
  1. 检出代码
  2. 设置 JDK 17
  3. 创建 `local.properties`（设置 SDK 路径）
  4. 执行 `./gradlew assembleRelease`
  5. 上传 APK 作为构建产物

#### 4.2 构建环境说明
- 由于项目包含 C++ 原生代码（CMake + NDK），Gitee 构建环境需要安装 NDK
- Gitee CI 默认提供的 Android SDK 镜像包含 NDK，无需额外配置
- 构建产物：`src/android/app/build/outputs/apk/release/app-release.apk`

---

## 四、改动文件清单

| 文件 | 操作 | 说明 |
|------|------|------|
| `src/android/app/build.gradle.kts` | 修改 | 添加读取 `.env` 注入 BuildConfig，添加 noCompress zip |
| `MinisApp.kt` | 修改 | 添加自动创建 DeepSeek Provider 逻辑 |
| `ProviderSettingsScreen.kt`（需确认路径） | 修改 | 隐藏 DeepSeek API Key 显示/复制 |
| `SkillRepository.kt` | 修改 | 扩展 installBundledSkills() 安装 4 个技能 |
| `assets/bundled-skills/*.zip` | 新增 | 4 个技能 ZIP 包 |
| `mipmap-*/ic_launcher*.png` | 替换 | 所有密度图标的 launcher PNG |
| `mipmap-night-*/ic_launcher*.png` | 替换 | 暗色模式图标 |
| `drawable/ic_launcher_monochrome.xml` | 可选修改 | 更新单色图标轮廓 |
| `.gitee/workflows/build-android.yml` | 新增 | Gitee 云编译配置 |
| `.env` | 保留 | 已有，供构建时读取 |

---

## 五、关键设计决策

1. **DeepSeek Key 安全性**：Key 通过构建时注入 → BuildConfig → EncryptedSharedPreferences 三重保护，用户无法从 UI 查看或复制，即使 root 手机也无法轻松获取（加密存储）。
2. **技能预装策略**：使用 `ImportSource.BUNDLED` 标记，用户可以在设置中禁用/删除已安装的技能，下次启动不会重新安装已删除的技能。
3. **图标替换**：保留自适应图标 XML 结构，只替换 PNG 文件，保持对 Android 8+ (API 26+) 自适应图标和 Android 13+ 主题图标的支持。
4. **Gitee 编译**：使用 Gitee CI 的免费额度，构建产物通过工作流页面下载。

---

## 六、验证步骤

1. **DeepSeek 接入验证**：
   - 首次启动后检查 Provider 列表是否自动包含 "DeepSeek"
   - 发送一条消息验证能否正常调用 DeepSeek API
   - 进入 Provider 设置页，确认 API Key 不可见/不可复制

2. **技能安装验证**：
   - 启动后检查技能列表是否包含 4 个新技能
   - 触发一个技能（如"生成周报"），验证技能是否正常工作

3. **图标验证**：
   - 桌面图标显示为新图标
   - 自适应图标在不同形状（圆形、圆角矩形、方形）下正常显示
   - 暗色模式 + 亮色模式图标正常

4. **Gitee 编译验证**：
   - 推送代码后触发自动构建
   - 构建成功后下载 APK 并安装验证