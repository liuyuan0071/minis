pluginManagement {
    repositories {
        // [T-gitee-go-build] Aliyun mirrors first so builds on Gitee Go's
        // China-based machines can resolve plugins/dependencies quickly;
        // official repos remain as fallbacks.
        maven("https://maven.aliyun.com/repository/gradle-plugin")
        maven("https://maven.aliyun.com/repository/google")
        maven("https://maven.aliyun.com/repository/central")
        google()
        mavenCentral()
        gradlePluginPortal()
    }
}

dependencyResolutionManagement {
    // PREFER_SETTINGS (not FAIL_ON_PROJECT_REPOS): Gitee Go's build plugin
    // injects an init.gradle that adds its internal maven mirror at the
    // PROJECT level. FAIL_ON_PROJECT_REPOS rejects that injection and the
    // build dies with "repository 'maven' was added by initialization script".
    repositoriesMode.set(RepositoriesMode.PREFER_SETTINGS)
    repositories {
        maven("https://maven.aliyun.com/repository/google")
        maven("https://maven.aliyun.com/repository/central")
        google()
        mavenCentral()
    }
}

rootProject.name = "Minis"
include(":app")
