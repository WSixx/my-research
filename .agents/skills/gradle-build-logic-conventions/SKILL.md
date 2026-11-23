---
name: gradle-build-logic-conventions
description: Design, audit, refactor, and validate Gradle `build-logic` composite-build convention plugins for multi-module Android, Kotlin, and JVM projects. Enforces modern Gradle 8/9 and AGP 8/9 best practices: `includeBuild`, shared version catalogs, `compileOnly` + `gradle-api`, strict `validatePlugins`, order-independent plugin reactions, modular capability plugins, DSL extensions, Configuration Cache, and Project Isolation readiness.
---

# Gradle `build-logic` Convention Plugins — Best Practices Skill

Use this skill whenever creating, auditing, migrating (from `buildSrc` or root `subprojects {}`), or cleaning up a Gradle `build-logic` included build. All rules below are **project-agnostic** and apply to any multi-module Android / Kotlin / JVM repository.

---

## 1. Directory Structure & Repository Hygiene

Use a composite build included from root `settings.gradle.kts` (`pluginManagement { includeBuild("build-logic") }`) instead of `buildSrc`.

```text
<repo-root>/
├── gradle/
│   ├── libs.versions.toml
│   └── wrapper/
│       └── gradle-wrapper.properties
├── gradle.properties
├── settings.gradle.kts              # pluginManagement { includeBuild("build-logic") }
├── build.gradle.kts                 # External plugins declared with `apply false`
└── build-logic/
    ├── settings.gradle.kts          # Own repositories + shared `../gradle/libs.versions.toml`
    └── convention/
        ├── build.gradle.kts         # `kotlin-dsl`, compileOnly deps, validatePlugins, gradlePlugin {}
        └── src/main/kotlin/
            └── <org>/<project>/buildlogic/
                ├── ProjectExtensions.kt
                ├── KotlinAndroid.kt
                ├── AndroidApplicationConventionPlugin.kt
                ├── AndroidLibraryConventionPlugin.kt
                ├── AndroidComposeConventionPlugin.kt
                └── ...
```

### Mandatory Hygiene Rules
1. **No duplicate Gradle wrapper inside `build-logic/`:** Do not keep `build-logic/gradle/wrapper/gradle-wrapper.properties` or `gradlew` scripts inside `build-logic/`. An included build automatically inherits the root Gradle wrapper.
2. **No redundant `build-logic/gradle.properties`:** Avoid duplicating root flags (`org.gradle.parallel`, `org.gradle.caching`) or enabling legacy flags like `org.gradle.configureondemand=true`. Only add a `build-logic/gradle.properties` if the included build genuinely requires distinct settings.
3. **Never commit IDE output mirrors (`bin/`):** Eclipse/VS Code Java/Kotlin tooling can generate `build-logic/convention/bin/main/*.kt`, silently duplicating source files with stale copies. Always ignore build/IDE outputs in root `.gitignore`:
   ```gitignore
   **/.gradle/
   **/.kotlin/
   **/build/
   **/bin/
   ```
4. **Always use a named Kotlin package:** Place all convention plugin classes and helpers under a dedicated package (e.g., `com.example.buildlogic`), never in the default (root) package.

---

## 2. `build-logic/settings.gradle.kts`

Included builds do not inherit repository declarations or version catalogs from the root `settings.gradle.kts`. Declare them explicitly and enforce centralized repository resolution:

```kotlin
pluginManagement {
    repositories {
        google {
            content {
                includeGroupByRegex("com\\.android.*")
                includeGroupByRegex("com\\.google.*")
                includeGroupByRegex("androidx.*")
            }
        }
        mavenCentral()
        gradlePluginPortal()
    }
}

dependencyResolutionManagement {
    repositoriesMode.set(RepositoriesMode.FAIL_ON_PROJECT_REPOS)
    repositories {
        google {
            content {
                includeGroupByRegex("com\\.android.*")
                includeGroupByRegex("com\\.google.*")
                includeGroupByRegex("androidx.*")
            }
        }
        mavenCentral()
    }
    versionCatalogs {
        create("libs") {
            from(files("../gradle/libs.versions.toml"))
        }
    }
}

rootProject.name = "build-logic"
include(":convention")
```

---

## 3. `build-logic/convention/build.gradle.kts` & Version Catalog

### 3.1. Prefer `compileOnly` + `gradle-api`
When the root `build.gradle.kts` declares external Gradle plugins with `apply false`, depend on them with `compileOnly` in `build-logic/convention/build.gradle.kts` to avoid duplicate plugin classpath loading and version conflicts.

For Android Gradle Plugin (AGP), prefer `com.android.tools.build:gradle-api` over `com.android.tools.build:gradle` so convention plugins can only compile against stable public AGP APIs:

```toml
# gradle/libs.versions.toml
[libraries]
android-gradleApiPlugin = { group = "com.android.tools.build", name = "gradle-api", version.ref = "agp" }
kotlin-gradlePlugin = { group = "org.jetbrains.kotlin", name = "kotlin-gradle-plugin", version.ref = "kotlin" }
compose-gradlePlugin = { module = "org.jetbrains.kotlin:compose-compiler-gradle-plugin", version.ref = "kotlin" }

[plugins]
# Project convention plugins (version = "unspecified" because they come from includeBuild)
project-android-application = { id = "project.android.application", version = "unspecified" }
project-android-library = { id = "project.android.library", version = "unspecified" }
project-android-compose = { id = "project.android.compose", version = "unspecified" }
```

> **Note:** Only use `implementation` for a plugin dependency if the root `build.gradle.kts` intentionally does **not** put that plugin on the root classpath.

### 3.2. Enforce Strict Plugin Validation & Single-Source Plugin IDs

```kotlin
import org.jetbrains.kotlin.gradle.dsl.JvmTarget

plugins {
    `kotlin-dsl`
}

group = "com.example.buildlogic"

java {
    sourceCompatibility = JavaVersion.VERSION_17
    targetCompatibility = JavaVersion.VERSION_17
}

kotlin {
    compilerOptions {
        jvmTarget = JvmTarget.JVM_17
    }
}

dependencies {
    compileOnly(libs.android.gradleApiPlugin)
    compileOnly(libs.kotlin.gradlePlugin)
    compileOnly(libs.compose.gradlePlugin)
}

tasks {
    validatePlugins {
        enableStricterValidation = true
        failOnWarning = true
    }
}

gradlePlugin {
    plugins {
        register("androidApplication") {
            id = libs.plugins.project.android.application.get().pluginId
            implementationClass = "com.example.buildlogic.AndroidApplicationConventionPlugin"
        }
        register("androidLibrary") {
            id = libs.plugins.project.android.library.get().pluginId
            implementationClass = "com.example.buildlogic.AndroidLibraryConventionPlugin"
        }
        register("androidCompose") {
            id = libs.plugins.project.android.compose.get().pluginId
            implementationClass = "com.example.buildlogic.AndroidComposeConventionPlugin"
        }
    }
}
```

---

## 4. Convention Plugin Design Principles

### 4.1. Granular Capability Plugins (No Bloated Base Plugins)
Keep base plugins (`android.application`, `android.library`) minimal. Extract opt-in capabilities into dedicated convention plugins so modules only pay for what they use:
- `*.android.compose` — Compose compiler plugin, `buildFeatures.compose = true`, Compose BOM.
- `*.android.native` — `ndkVersion`, `externalNativeBuild.cmake.version`, `ndk.abiFilters` (so pure-Kotlin library modules never touch NDK/CMake).
- `*.android.publishing` — `maven-publish`, `singleVariant("release") { withSourcesJar() }`, POM metadata, remote repository credentials.
- `*.android.hilt`, `*.android.room`, `*.jvm.library`, etc.

### 4.2. Order-Independent Plugin Reactions
Never assume another plugin was applied before yours by calling `extensions.getByType<CommonExtension>()` eagerly in `apply()`. Always react via `plugins.withId(...)`:

```kotlin
class AndroidComposeConventionPlugin : Plugin<Project> {
    override fun apply(target: Project) {
        with(target) {
            apply(plugin = "org.jetbrains.kotlin.plugin.compose")

            plugins.withId("com.android.application") {
                configureAndroidCompose(extensions.getByType<ApplicationExtension>())
            }
            plugins.withId("com.android.library") {
                configureAndroidCompose(extensions.getByType<LibraryExtension>())
            }
        }
    }
}
```

Similarly, cross-capability hooks should react to marker plugin IDs (e.g., `plugins.withId("project.android.native") { ... }`) rather than checking module names.

### 4.3. DSL Extensions Instead of Hardcoded Module Paths
Never branch on `project.path == ":core"` or hardcode module-specific POM names/paths inside a convention plugin. Expose a typed Gradle extension with `.convention(...)` defaults:

```kotlin
abstract class ProjectPublishingExtension {
    abstract val artifactId: Property<String>
    abstract val pomName: Property<String>
    abstract val pomDescription: Property<String>
}

// Inside plugin apply():
val publishingConfig = extensions.create<ProjectPublishingExtension>("projectPublishing").apply {
    artifactId.convention(name)
    pomName.convention(name)
    pomDescription.convention("Library module $name")
}
```

Consumer module `build.gradle.kts`:
```kotlin
plugins {
    id("project.android.library")
    id("project.android.publishing")
}

projectPublishing {
    pomName = "Core Engine"
}
```

### 4.4. Configuration Cache & Project Isolation Readiness
Write plugins so they remain compatible with Gradle's **Configuration Cache** and **Project Isolation**:
- **Lazy task & provider APIs:** Use `tasks.register`, `Property`, `RegularFileProperty`, `DirectoryProperty`, `providers.gradleProperty(...)`, `providers.environmentVariable(...)`, and `providers.fileContents(...)`.
- **No cross-project traversal:** Never call `rootProject.findProject(...)`, `allprojects {}`, `subprojects {}`, or read another subproject's extension/tasks directly from a convention plugin.
- **Root project check & root directory access:**
  - Check root project via `path == ":"` rather than `this == rootProject`.
  - Resolve root-level shared files (e.g., `version.properties`, `CHANGELOG.md`, `gradle/libs.versions.toml`) via `isolated.rootProject.projectDirectory` rather than walking `projectDir.parentFile` or touching `rootProject.file(...)`.
- **AGP Variant API over internal paths:** Prefer `androidComponents.onVariants { ... }` (for example, `variant.sources.kotlin?.addGeneratedSourceDirectory(...)`) over reaching into `build/intermediates/...` whenever AGP exposes a public artifact API.

### 4.5. Mandatory Cacheability Annotations on Custom Tasks
Because `validatePlugins` runs with `enableStricterValidation = true` and `failOnWarning = true`, every custom `DefaultTask` subclass **must** explicitly declare its caching contract:

| Task Behavior | Required Annotation |
| --- | --- |
| Deterministic inputs and outputs (code gen, SBOM, reports) | `@CacheableTask` + `@Input` / `@InputFile` with `@PathSensitive(...)` + `@OutputFile` / `@OutputDirectory` |
| Side-effect / console output / read-only verification gate without outputs | `@DisableCachingByDefault(because = "...")` |
| Mutates tracked source files in place (e.g., version bumper) | `@UntrackedTask(because = "...")` |

---

## 5. Audit & Refactoring Workflow

When auditing or setting up `build-logic` in a project, follow these steps in order:

1. **Inspect layout & tracked files:**
   - Verify `includeBuild("build-logic")` is in root `settings.gradle.kts`.
   - Check `git ls-files build-logic` for accidentally committed `bin/`, `build/`, duplicate `gradle/wrapper/`, or redundant `gradle.properties`.
   - Ensure `.gitignore` includes `**/bin/`, `**/build/`, `**/.gradle/`, and `**/.kotlin/`.
2. **Audit `build-logic/settings.gradle.kts` & `convention/build.gradle.kts`:**
   - Confirm `RepositoriesMode.FAIL_ON_PROJECT_REPOS` and shared `libs.versions.toml`.
   - Confirm `compileOnly` + `gradle-api`, `validatePlugins` strict mode, and fully qualified `implementationClass` names.
3. **Audit plugin decoupling & isolation:**
   - Split optional capabilities (Compose, NDK/CMake, Publishing, DI) out of base plugins.
   - Replace eager `getByType<CommonExtension>()` calls with `plugins.withId(...)`.
   - Replace hardcoded `project.path` switches and `rootProject.findProject(...)` with DSL extensions, `plugins.withId(...)`, and `isolated.rootProject.projectDirectory`.
   - Ensure every `DefaultTask` has `@CacheableTask`, `@DisableCachingByDefault`, or `@UntrackedTask` and proper input/output annotations.
4. **Sync & Verify:**
   - Run Gradle Sync.
   - Run `./gradlew :build-logic:convention:check` (must pass `validatePlugins` with zero warnings).
   - Run representative root and subproject tasks (unit tests + debug assemble) to confirm classpath resolution with `compileOnly`.

---

## 6. Anti-Patterns Checklist

| Anti-Pattern | Replacement |
| --- | --- |
| Putting convention plugins in `buildSrc` | Use `includeBuild("build-logic")` composite build |
| Keeping `build-logic/gradle/wrapper/` or duplicate `gradle.properties` | Inherit root wrapper and root `gradle.properties` |
| Committing `build-logic/convention/bin/` | Delete `bin/` and add `**/bin/` to `.gitignore` |
| Depending on `implementation(libs.android.gradlePlugin)` when root uses `apply false` | Use `compileOnly(libs.android.gradleApiPlugin)` |
| Putting `*ConventionPlugin` in the default package | Place plugins under `<org>.<project>.buildlogic` |
| Calling `extensions.getByType<CommonExtension>()` eagerly | React via `plugins.withId("com.android.application")` / `plugins.withId("com.android.library")` |
| Configuring NDK/CMake/Compose in base `android.library` plugin | Extract `*.android.native` / `*.android.compose` opt-in plugins |
| Switching on `project.path` or calling `rootProject.findProject(...)` | Expose a typed Gradle DSL extension + `plugins.withId(...)` + `isolated.rootProject.projectDirectory` |
| Leaving custom tasks without cacheability annotations | Annotate with `@CacheableTask`, `@DisableCachingByDefault`, or `@UntrackedTask` |
