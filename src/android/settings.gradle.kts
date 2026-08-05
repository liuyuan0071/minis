pluginManagement {
    repositories {
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
        google()
        mavenCentral()
    }
}

rootProject.name = "Minis"
include(":app")