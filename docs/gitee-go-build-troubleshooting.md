# Gitee Go 云编译环境问题排查存档

> 记录 OpenMinis Android 项目在 Gitee Go 云编译（`build@android` 插件，镜像 `ubuntu:plugin-24`）过程中遇到的全部环境问题、根因与解决方案。
> 适用流水线：`.workflow/build-android.yml`（Gitee Go 流水线会将其写回仓库）。

---

## 环境事实（已探测确认，2026-08-05）

| 项目 | 值 |
|---|---|
| 构建镜像 | `ccr-57qb48sp-vpc.cnc.su.baidubce.com/saas-gitee-go/ubuntu:plugin-24` |
| CPU / 内存 | 2 核 / 4Gi |
| JDK | 17（`PLUGIN_JAVA_VERSION=17`） |
| Android SDK 目录 | `/mnt/pipeline-tools/standard/android/sdk`（**只读**） |
| 预装 NDK | `27.3.13750724`、`28.2.13676358` |
| 预装 build-tools / platforms / platform-tools | 有 |
| 预装 CMake | **无**（SDK 无 cmake 目录） |
| 预装 Ninja | 无（需 apt 安装） |
| 网络可达性 | 腾讯云镜像 ✓、Termux(packages.termux.dev) ✓、Alpine CDN ✓；`services.gradle.org` ✗、GitHub 下载大文件不稳定（HTTP2 错误） |

---

## 问题清单

### 1. Gradle 发行包下载超时（致命，构建第一步就挂）

- **现象**：`Downloading from https://services.gradle.org/distributions/gradle-8.11.1-bin.zip failed: timeout (10000ms)` + `SocketTimeoutException`
- **根因**：Gitee 构建机无法访问 Gradle 官方源 `services.gradle.org`
- **解决**：改 `src/android/gradle/wrapper/gradle-wrapper.properties`
  - `distributionUrl` → `https://mirrors.cloud.tencent.com/gradle/gradle-8.11.1-bin.zip`（已验证 HTTP 200，~137MB，秒下）
  - `networkTimeout` 10000 → 60000
- **验证**：日志显示 `Welcome to Gradle 8.11.1!` ✅

### 2. Termux PRoot 下载 404

- **现象**：`curl: (22) The requested URL returned error: 404`，proot 下载失败（当时为非致命，`|| echo` 兜底）
- **根因**：`scripts/prepare_android_sandbox.sh` 中 `PROOT_VERSION="5.1.107-70"` 版本号错误——Termux 仓库真实版本为 `5.1.107.89`（分隔符是 `.` 不是 `-`）
- **解决**：改为 `5.1.107.89`（对照 `packages.termux.dev/.../binary-aarch64/Packages` 索引确认）
- **验证**：`✓ Extracted PRoot binary (236K)` ✅

### 3. repositoriesMode 与 Gitee Go 注入的 init.gradle 冲突（致命）

- **现象**：
  ```
  Initialization script '/root/.gradle/init.gradle' line: 18
  Build was configured to prefer settings repositories over project repositories
  but repository 'maven' was added by initialization script
  ```
- **根因**：Gitee Go 的 gradle-build 插件会注入 `init.gradle`，在**项目级**添加内部 maven 镜像。项目 `settings.gradle.kts` 设置了 `RepositoriesMode.FAIL_ON_PROJECT_REPOS`，禁止任何项目级仓库 → 冲突抛异常
- **解决**：`settings.gradle.kts` 改为 `RepositoriesMode.PREFER_SETTINGS`（settings 仓库优先，放行插件注入），并前置阿里云 maven 镜像（google/central/gradle-plugin）
- **验证**：依赖解析通过 ✅

### 4. NDK 版本未预装 + SDK 目录只读（致命）

- **现象**：
  ```
  Failed to install the following SDK components:
      ndk;27.0.12077973 NDK (Side by side) 27.0.12077973
  The SDK directory is not writable (/mnt/pipeline-tools/standard/android/sdk)
  ```
- **根因**：AGP 默认 NDK 27.0.12077973（AGP 8.7.3）在环境中不存在，AGP 尝试自动安装到只读 SDK → 失败
- **解决**：`build.gradle.kts` 固定 `ndkVersion = "27.3.13750724"`（环境预装版本）
  - ⚠️ 曾尝试"探测 + sed 适配"方案，但 Gitee Go 网页配置与仓库文件不同步导致命令未生效；最终直接固定版本，最可靠
- **验证**：`configureCMakeRelWithDebInfo[arm64-v8a]` 通过 ✅

### 5. 环境无 CMake + 无 Ninja（致命）

- **现象**：
  ```
  > [CXX1416] Could not find Ninja on PATH or in SDK CMake bin folders.
  ```
- **根因**：SDK 无 cmake 目录（探测确认），AGP 找不到原生编译工具链；且 Kitware 官方 CMake 包本身不含 ninja
- **解决**（流水线命令中添加）：
  ```bash
  apt-get update -y >/dev/null 2>&1 || true
  apt-get install -y ninja-build cmake >/dev/null 2>&1 || echo "..."
  ```
  ninja 进入 PATH 供 AGP 使用；cmake 作为兜底
- **验证**：`buildCMakeRelWithDebInfo[arm64-v8a]` 成功 ✅

### 6. GitHub 下载 CMake 报 HTTP2 framing 错误（非致命，但导致下载失败）

- **现象**：`curl: (16) Error in the HTTP2 framing layer` / `curl: (56) OpenSSL SSL_read: Connection reset by peer`
- **根因**：构建机访问 GitHub release 大文件时 HTTP2 连接不稳定
- **解决**：curl 加 `--http1.1` 强制 HTTP/1.1；配合 apt 的 ninja/cmake 兜底，即使下载失败也能继续构建
- **验证**：即使 CMake 下载失败，apt 的 cmake/ninja 也能完成原生编译 ✅

---

## 配套代码问题（同轮排查记录）

### 7. Kotlin KDoc 注释中的 `/*` 触发嵌套注释（致命编译错误）

- **现象**：
  ```
  SkillRepository.kt:1150:6 Missing '}'
  SkillRepository.kt:1589:1 Unclosed comment
  ```
- **根因**：`installBundledSkillPacks()` 的 KDoc 注释里写了 `` `assets/bundled-skills/*.zip` `` ——Kotlin 块注释**支持嵌套**，`/*` 序列开启了内层注释，导致外层注释无法闭合、后续代码全部被吞
- **解决**：注释改为不含 `/*` 的写法（`assets/bundled-skills/` 下的 .zip 文件）
- **教训**：Kotlin 块注释内不要写含 `/*` 的文本（路径通配符、`*` 加 `/` 的组合）

---

## 当前流水线命令（最终可用版）

```bash
echo "DEEPSEEK_API_KEY=$DEEPSEEK_API_KEY" > .env
bash ./scripts/prepare_android_sandbox.sh || echo "沙箱资源准备失败（非阻断，聊天/技能功能不受影响）"
apt-get update -y >/dev/null 2>&1 || true; apt-get install -y ninja-build cmake >/dev/null 2>&1 || echo "apt 安装 cmake/ninja 失败（非阻断）"
mkdir -p $HOME/cmake; curl --http1.1 -fsSL --retry 3 -o $HOME/cmake.tar.gz "https://github.com/Kitware/CMake/releases/download/v3.22.1/cmake-3.22.1-linux-x86_64.tar.gz" && tar xzf $HOME/cmake.tar.gz -C $HOME/cmake --strip-components=1 && echo "cmake.dir=$HOME/cmake" >> src/android/local.properties && echo "CMake 3.22.1 就绪" || echo "CMake 下载失败，将使用系统 cmake/ninja"
cd src/android
chmod +x gradlew
./gradlew :app:assembleRelease --no-daemon --stacktrace
```

流水线插件参数（`build@android`）：
- `gradleVersion: "9.3"`（实际 Gradle 由 wrapper 腾讯云镜像决定，此项影响不大）
- `buildToolsVersion: 36.1.0`
- `ndkVersion: 27.3.13750724`（与 `build.gradle.kts` 固定值一致）

## 保留的代码侧修复（已入仓库）

| 文件 | 改动 |
|---|---|
| `src/android/gradle/wrapper/gradle-wrapper.properties` | Gradle 发行包 → 腾讯云镜像；超时 60s |
| `src/android/settings.gradle.kts` | `PREFER_SETTINGS`；前置阿里云 maven 镜像 |
| `src/android/app/build.gradle.kts` | `ndkVersion = "27.3.13750724"`；`noCompress` 加 zip |
| `scripts/prepare_android_sandbox.sh` | proot 版本 `5.1.107-70` → `5.1.107.89` |
| `src/android/.../SkillRepository.kt` | 修复 KDoc 注释 `/*` 嵌套注释 bug |
