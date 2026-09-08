import java.io.FileInputStream
import java.util.Properties

plugins {
    id("com.android.application")
    // Flutter Gradle 플러그인은 Android 및 Kotlin Gradle 플러그인 뒤에 적용해야 한다.
    id("dev.flutter.flutter-gradle-plugin")
}

// 릴리스 산출물은 앱 전용 업로드 키로 서명해야 한다.
// 값은 android/key.properties(git에서 무시됨)나 CI 환경 변수에서 가져올 수
// 있다. 비밀번호나 키 저장소를 소스 관리에 절대 넣지 않는다.
val keyProperties = Properties()
val keyPropertiesFile = rootProject.file("key.properties")
if (keyPropertiesFile.isFile) {
    FileInputStream(keyPropertiesFile).use { keyProperties.load(it) }
}

fun signingValue(propertyName: String, environmentName: String): String? {
    return keyProperties.getProperty(propertyName)?.trim()?.takeIf { it.isNotEmpty() }
        ?: providers.environmentVariable(environmentName).orNull?.trim()?.takeIf { it.isNotEmpty() }
}

val releaseStoreFilePath = signingValue("storeFile", "MODULY_ANDROID_KEYSTORE_FILE")
val releaseStorePassword = signingValue("storePassword", "MODULY_ANDROID_KEYSTORE_PASSWORD")
val releaseKeyAlias = signingValue("keyAlias", "MODULY_ANDROID_KEY_ALIAS")
val releaseKeyPassword = signingValue("keyPassword", "MODULY_ANDROID_KEY_PASSWORD")
val releaseSigningValuesPresent = listOf(
    releaseStoreFilePath,
    releaseStorePassword,
    releaseKeyAlias,
    releaseKeyPassword,
).all { it != null }
// key.properties가 있는 android/를 기준으로 상대 경로를 해석한다. CI에서
// 마운트한 키 저장소에는 절대 경로도 사용할 수 있다.
val releaseStoreFile = releaseStoreFilePath?.let { rootProject.file(it) }
val releaseSigningReady = releaseSigningValuesPresent && releaseStoreFile?.isFile == true

android {
    namespace = "com.herbcookey.moduly"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
        // flutter_local_notifications는 예약 알림에 java.time API를 사용한다.
        // 정확한 알람 권한을 요청하지 않으면서 플러그인에 필요한 라이브러리
        // 디슈거링을 활성 상태로 유지한다.
        isCoreLibraryDesugaringEnabled = true
    }

    defaultConfig {
        applicationId = "com.herbcookey.moduly"
        // 다음 값을 앱 요구사항에 맞게 바꿀 수 있다.
        // 자세한 내용은 https://flutter.dev/to/review-gradle-config를 참고한다.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        // 이름이 명시된 릴리스 설정을 유지한다. 아래에서 모든 값이 있을 때만
        // 할당하므로 새 체크아웃에서도 디버그/프로필 빌드는 사용할 수 있고,
        // 릴리스 빌드는 명확한 메시지와 함께 실패한다.
        create("release") {
            if (releaseSigningReady) {
                storeFile = releaseStoreFile
                storePassword = releaseStorePassword
                keyAlias = releaseKeyAlias
                keyPassword = releaseKeyPassword
            }
        }
    }

    buildTypes {
        release {
            if (releaseSigningReady) {
                signingConfig = signingConfigs.getByName("release")
            }
        }
    }

}

dependencies {
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.4")
}

// AGP는 릴리스 서명 설정이 불완전하면 서명되지 않은 산출물을 만들거나
// 디버그 키로 대체할 수 있다. 실제 릴리스 작업을 요청할 때만 실패시켜
// 로컬 디버그/프로필 작업 흐름은 계속 사용할 수 있게 한다.
tasks.configureEach {
    if (name == "preReleaseBuild" || name == "assembleRelease" || name == "bundleRelease") {
        doFirst {
            if (!releaseSigningReady) {
                val source = if (keyPropertiesFile.isFile) {
                    "android/key.properties"
                } else {
                    "MODULY_ANDROID_* 환경 변수"
                }
                throw GradleException(
                    "릴리스 서명이 설정되지 않았습니다. ${source}에 storeFile, " +
                        "storePassword, keyAlias, keyPassword를 지정하세요 " +
                        "(android/key.properties.example 참고). 릴리스 빌드에는 " +
                        "디버그 키 저장소를 사용하지 않습니다.",
                )
            }
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}
