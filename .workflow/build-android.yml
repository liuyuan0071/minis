version: '1.0'
name: pipeline-android
displayName: Android APK 云编译
triggers:
  trigger: auto
  push:
    branches:
      prefix:
        - master
variables:
  global:
    # 在流水线【变量设置】中添加同名变量，填入你的 DeepSeek API Key
    - DEEPSEEK_API_KEY
stages:
  - name: stage-build
    displayName: 构建 APK
    steps:
      - step: build@android
        name: build_android
        displayName: Android 构建
        jdkVersion: 17
        commands:
          - echo "DEEPSEEK_API_KEY=$DEEPSEEK_API_KEY" > .env
          - bash ./scripts/prepare_android_sandbox.sh || echo "沙箱资源准备失败（非阻断，聊天/技能功能不受影响）"
          # 环境 SDK 只读且无 CMake：下载官方 CMake 3.22.1 到可写目录，通过 cmake.dir 指定给 AGP
          - mkdir -p $HOME/cmake; curl -fsSL --retry 3 -o $HOME/cmake.tar.gz "https://github.com/Kitware/CMake/releases/download/v3.22.1/cmake-3.22.1-linux-x86_64.tar.gz" && tar xzf $HOME/cmake.tar.gz -C $HOME/cmake --strip-components=1 && echo "cmake.dir=$HOME/cmake" >> src/android/local.properties && echo "CMake 3.22.1 就绪" || echo "CMake 准备失败（非阻断，构建可能报错）"
          - cd src/android
          - chmod +x gradlew
          - ./gradlew :app:assembleRelease --no-daemon --stacktrace
        artifacts:
          - name: APK
            path:
              - src/android/app/build/outputs/apk/release/*.apk
