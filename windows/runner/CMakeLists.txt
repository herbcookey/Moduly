cmake_minimum_required(VERSION 3.14)
project(runner LANGUAGES CXX)

# 앱 대상을 정의한다. 이름을 바꾸려면 여기 값이 아니라 최상위
# CMakeLists.txt의 BINARY_NAME을 바꿔야 `flutter run`이 계속 동작한다.
#
# 앱에 추가하는 새 소스 파일은 여기에 추가해야 한다.
add_executable(${BINARY_NAME} WIN32
  "flutter_window.cpp"
  "main.cpp"
  "utils.cpp"
  "win32_window.cpp"
  "${FLUTTER_MANAGED_DIR}/generated_plugin_registrant.cc"
  "Runner.rc"
  "runner.exe.manifest"
)

# 표준 빌드 설정을 적용한다. 다른 빌드 설정이 필요한 앱에서는 제거할 수 있다.
apply_standard_settings(${BINARY_NAME})

# 빌드 버전용 전처리기 정의를 추가한다.
target_compile_definitions(${BINARY_NAME} PRIVATE "FLUTTER_VERSION=\"${FLUTTER_VERSION}\"")
target_compile_definitions(${BINARY_NAME} PRIVATE "FLUTTER_VERSION_MAJOR=${FLUTTER_VERSION_MAJOR}")
target_compile_definitions(${BINARY_NAME} PRIVATE "FLUTTER_VERSION_MINOR=${FLUTTER_VERSION_MINOR}")
target_compile_definitions(${BINARY_NAME} PRIVATE "FLUTTER_VERSION_PATCH=${FLUTTER_VERSION_PATCH}")
target_compile_definitions(${BINARY_NAME} PRIVATE "FLUTTER_VERSION_BUILD=${FLUTTER_VERSION_BUILD}")

# C++ 표준 라이브러리 함수와 충돌하는 Windows 매크로를 비활성화한다.
target_compile_definitions(${BINARY_NAME} PRIVATE "NOMINMAX")

# 종속 라이브러리와 include 디렉터리를 추가한다. 앱별 종속성도 여기에 추가한다.
target_link_libraries(${BINARY_NAME} PRIVATE flutter flutter_wrapper_app)
target_link_libraries(${BINARY_NAME} PRIVATE "dwmapi.lib")
target_include_directories(${BINARY_NAME} PRIVATE "${CMAKE_SOURCE_DIR}")

# Flutter 도구가 담당하는 빌드 부분을 실행한다. 삭제하면 안 된다.
add_dependencies(${BINARY_NAME} flutter_assemble)
