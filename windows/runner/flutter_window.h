#ifndef RUNNER_FLUTTER_WINDOW_H_
#define RUNNER_FLUTTER_WINDOW_H_

#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>

#include <memory>

#include "win32_window.h"

// Flutter 뷰를 호스팅하는 역할만 하는 창이다.
class FlutterWindow : public Win32Window {
 public:
  // |project|를 실행하는 Flutter 뷰를 호스팅하는 새 FlutterWindow을 만든다.
  explicit FlutterWindow(const flutter::DartProject& project);
  virtual ~FlutterWindow();

 protected:
  // Win32Window 상속 구현:
  bool OnCreate() override;
  void OnDestroy() override;
  LRESULT MessageHandler(HWND window, UINT const message, WPARAM const wparam,
                         LPARAM const lparam) noexcept override;

 private:
  // 실행할 프로젝트다.
  flutter::DartProject project_;

  // 창이 호스팅하는 Flutter 인스턴스다.
  std::unique_ptr<flutter::FlutterViewController> flutter_controller_;
};

#endif  // RUNNER_FLUTTER_WINDOW_H_
