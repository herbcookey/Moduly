# 프로젝트 수준 설정이다.
cmake_minimum_required(VERSION 3.13)
project(runner LANGUAGES CXX)

# 앱에서 생성할 실행 파일 이름이다. 바꾸면 디스크에 저장되는 앱 이름도 바뀐다.
set(BINARY_NAME "moduly")
# 앱의 고유 GTK 애플리케이션 식별자다. 참고:
# https://wiki.gnome.org/HowDoI/ChooseApplicationID
set(APPLICATION_ID "com.herbcookey.moduly")

# 최신 CMake 버전의 경고를 피하도록 최신 동작을 명시적으로 사용한다.
cmake_policy(SET CMP0063 NEW)

# 실행 파일 기준 lib/ 디렉터리에서 번들 라이브러리를 불러온다.
set(CMAKE_INSTALL_RPATH "$ORIGIN/lib")

# 교차 빌드에 사용할 루트 파일 시스템이다.
if(FLUTTER_TARGET_PLATFORM_SYSROOT)
  set(CMAKE_SYSROOT ${FLUTTER_TARGET_PLATFORM_SYSROOT})
  set(CMAKE_FIND_ROOT_PATH ${CMAKE_SYSROOT})
  set(CMAKE_FIND_ROOT_PATH_MODE_PROGRAM NEVER)
  set(CMAKE_FIND_ROOT_PATH_MODE_PACKAGE ONLY)
  set(CMAKE_FIND_ROOT_PATH_MODE_LIBRARY ONLY)
  set(CMAKE_FIND_ROOT_PATH_MODE_INCLUDE ONLY)
endif()

# 빌드 설정 옵션을 정의한다.
if(NOT CMAKE_BUILD_TYPE AND NOT CMAKE_CONFIGURATION_TYPES)
  set(CMAKE_BUILD_TYPE "Debug" CACHE
    STRING "Flutter build mode" FORCE)
  set_property(CACHE CMAKE_BUILD_TYPE PROPERTY STRINGS
    "Debug" "Profile" "Release")
endif()

# 대부분의 대상에 적용할 컴파일 설정이다.
#
# 플러그인이 기본적으로 이 함수를 사용하므로 여기에 새 옵션을 추가할 때
# 주의한다. 대부분의 경우 이 함수를 바꾸기보다 특정 대상에 옵션을 추가한다.
function(APPLY_STANDARD_SETTINGS TARGET)
  target_compile_features(${TARGET} PUBLIC cxx_std_14)
  target_compile_options(${TARGET} PRIVATE -Wall -Werror)
  target_compile_options(${TARGET} PRIVATE "$<$<NOT:$<CONFIG:Debug>>:-O3>")
  target_compile_definitions(${TARGET} PRIVATE "$<$<NOT:$<CONFIG:Debug>>:NDEBUG>")
endfunction()

# Flutter 라이브러리 및 도구 빌드 규칙이다.
set(FLUTTER_MANAGED_DIR "${CMAKE_CURRENT_SOURCE_DIR}/flutter")
add_subdirectory(${FLUTTER_MANAGED_DIR})

# 시스템 수준 종속성이다.
find_package(PkgConfig REQUIRED)
pkg_check_modules(GTK REQUIRED IMPORTED_TARGET gtk+-3.0)

# 앱 빌드 규칙이다. runner/CMakeLists.txt를 참고한다.
add_subdirectory("runner")

# Flutter 도구가 담당하는 빌드 부분을 실행한다. 삭제하면 안 된다.
add_dependencies(${BINARY_NAME} flutter_assemble)

# 리소스가 올바른 상대 경로에 있어야 하므로 설치로 생성된 번들의 실행 파일만
# 정상적으로 실행된다. 번들되지 않은 파일을 실행하는 일을 막기 위해 기본
# 최상위 위치 대신 하위 디렉터리에 둔다.
set_target_properties(${BINARY_NAME}
  PROPERTIES
  RUNTIME_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}/intermediates_do_not_run"
)


# 플러그인 빌드와 앱 추가를 관리하는 생성된 플러그인 빌드 규칙이다.
include(flutter/generated_plugins.cmake)


# === 설치 ===
# 기본적으로 "install"은 빌드 디렉터리에 이동 가능한 번들만 만든다.
set(BUILD_BUNDLE_DIR "${PROJECT_BINARY_DIR}/bundle")
if(CMAKE_INSTALL_PREFIX_INITIALIZED_TO_DEFAULT)
  set(CMAKE_INSTALL_PREFIX "${BUILD_BUNDLE_DIR}" CACHE PATH "..." FORCE)
endif()

# 매번 깨끗한 빌드 번들 디렉터리에서 시작한다.
install(CODE "
  file(REMOVE_RECURSE \"${BUILD_BUNDLE_DIR}/\")
  " COMPONENT Runtime)

set(INSTALL_BUNDLE_DATA_DIR "${CMAKE_INSTALL_PREFIX}/data")
set(INSTALL_BUNDLE_LIB_DIR "${CMAKE_INSTALL_PREFIX}/lib")

install(TARGETS ${BINARY_NAME} RUNTIME DESTINATION "${CMAKE_INSTALL_PREFIX}"
  COMPONENT Runtime)

install(FILES "${FLUTTER_ICU_DATA_FILE}" DESTINATION "${INSTALL_BUNDLE_DATA_DIR}"
  COMPONENT Runtime)

install(FILES "${FLUTTER_LIBRARY}" DESTINATION "${INSTALL_BUNDLE_LIB_DIR}"
  COMPONENT Runtime)

foreach(bundled_library ${PLUGIN_BUNDLED_LIBRARIES})
  install(FILES "${bundled_library}"
    DESTINATION "${INSTALL_BUNDLE_LIB_DIR}"
    COMPONENT Runtime)
endforeach(bundled_library)

# 모든 패키지의 build.dart가 제공하는 네이티브 자산을 복사한다.
set(NATIVE_ASSETS_DIR "${PROJECT_BUILD_DIR}native_assets/linux/")
install(DIRECTORY "${NATIVE_ASSETS_DIR}"
   DESTINATION "${INSTALL_BUNDLE_LIB_DIR}"
   COMPONENT Runtime)

# 이전 설치의 오래된 파일이 남지 않도록 빌드마다 자산 디렉터리를 완전히
# 다시 복사한다.
set(FLUTTER_ASSET_DIR_NAME "flutter_assets")
install(CODE "
  file(REMOVE_RECURSE \"${INSTALL_BUNDLE_DATA_DIR}/${FLUTTER_ASSET_DIR_NAME}\")
  " COMPONENT Runtime)
install(DIRECTORY "${PROJECT_BUILD_DIR}/${FLUTTER_ASSET_DIR_NAME}"
  DESTINATION "${INSTALL_BUNDLE_DATA_DIR}" COMPONENT Runtime)

# Debug가 아닌 빌드에서만 AOT 라이브러리를 설치한다.
if(NOT CMAKE_BUILD_TYPE MATCHES "Debug")
  install(FILES "${AOT_LIBRARY}" DESTINATION "${INSTALL_BUNDLE_LIB_DIR}"
    COMPONENT Runtime)
endif()
