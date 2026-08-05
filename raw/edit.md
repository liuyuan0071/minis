version: "1.0"
name: pipeline-android
displayName: Android APK 云编译
stages:
- name: 构建 APK
  displayName: 构建 APK
  strategy: naturally
  trigger: auto
  steps:
  - step: build@android
    name: build_android
    displayName: Android 构建
    jdkVersion: "17"
    gradleVersion: "9.3"
    buildToolsVersion: 36.1.0
    ndkVersion: 27.3.13750724
    commands:
    - echo "DEEPSEEK_API_KEY=$DEEPSEEK_API_KEY" > .env
    - bash ./scripts/prepare_android_sandbox.sh || echo "沙箱资源准备失败（非阻断，聊天/技能功能不受影响）"
    - apt-get update -y >/dev/null 2>&1 || true; apt-get install -y ninja-build cmake >/dev/null 2>&1 && echo "apt cmake/ninja 就绪" || echo "apt 安装失败（非阻断）"
    - cd src/android
    - chmod +x gradlew
    - ./gradlew :app:assembleRelease --no-daemon --stacktrace
    artifacts:
    - name: APK
      path:
      - src/android/app/build/outputs/apk/release/*.apk
      type: .tar.gz
    strategy:
      retry: "0"
      # Gitee Go 任务超时上限 1440 分钟；显式声明，避免平台默认超时干扰
      stepTimeout: 1440
triggers:
  trigger: auto
  push:
    branches:
      prefix:
      - master
      precise: []
      include: []
notify: []
variables:
  global:
  - DEEPSEEK_API_KEY
