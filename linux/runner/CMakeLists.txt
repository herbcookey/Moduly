cmake_minimum_required(VERSION 3.13)
project(runner LANGUAGES CXX)

# 앱 대상을 정의한다. 이름을 바꾸려면 여기 값이 아니라 최상위
# CMakeLists.txt의 BINARY_NAME을 바꿔야 `flutter run`이 계속 동작한다.
#
# 앱에 추가하는 새 소스 파일은 여기에 추가해야 한다.
add_executable(${BINARY_NAME}
  "main.cc"
  "my_application.cc"
  "${FLUTTER_MANAGED_DIR}/generated_plugin_registrant.cc"
)

# 표준 빌드 설정을 적용한다. 다른 빌드 설정이 필요한 앱에서는 제거할 수 있다.
apply_standard_settings(${BINARY_NAME})

# 앱 식별자용 전처리기 정의를 추가한다.
add_definitions(-DAPPLICATION_ID="${APPLICATION_ID}")

# 종속 라이브러리를 추가한다. 앱별 종속성도 여기에 추가한다.
target_link_libraries(${BINARY_NAME} PRIVATE flutter)
target_link_libraries(${BINARY_NAME} PRIVATE PkgConfig::GTK)

target_include_directories(${BINARY_NAME} PRIVATE "${CMAKE_SOURCE_DIR}")
