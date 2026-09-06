#ifndef RUNNER_WIN32_WINDOW_H_
#define RUNNER_WIN32_WINDOW_H_

#include <windows.h>

#include <functional>
#include <memory>
#include <string>

// 높은 DPI를 인식하는 Win32 창의 추상화다. 맞춤 렌더링과 입력 처리를
// 구현하려는 클래스가 상속할 수 있다.
class Win32Window {
 public:
  struct Point {
    unsigned int x;
    unsigned int y;
    Point(unsigned int x, unsigned int y) : x(x), y(y) {}
  };

  struct Size {
    unsigned int width;
    unsigned int height;
    Size(unsigned int width, unsigned int height)
        : width(width), height(height) {}
  };

  Win32Window();
  virtual ~Win32Window();

  // |title|을 사용해 |origin|과 |size|로 배치/크기 지정한 Win32 창을 만든다.
  // 새 창은 기본 모니터에 만든다. 창 크기는 OS에 물리 픽셀로 전달되므로
  // 일관된 크기를 위해 기본 모니터에 맞춰 입력 너비와 높이를 조정한다.
  // |Show|를 호출할 때까지 창은 보이지 않는다. 성공하면 true를 반환한다.
  bool Create(const std::wstring& title, const Point& origin, const Size& size);

  // 현재 창을 표시한다. 성공적으로 표시하면 true를 반환한다.
  bool Show();

  // 창과 관련된 OS 리소스를 해제한다.
  void Destroy();

  // |content|를 창 트리에 삽입한다.
  void SetChildContent(HWND content);

  // 호출자가 아이콘과 창 속성을 설정할 수 있도록 실제 Window 핸들을
  // 반환한다. 창이 제거되었으면 nullptr을 반환한다.
  HWND GetHandle();

  // true이면 이 창을 닫을 때 앱을 종료한다.
  void SetQuitOnClose(bool quit_on_close);

  // 현재 클라이언트 영역의 경계를 나타내는 RECT를 반환한다.
  RECT GetClientArea();

 protected:
  // 마우스 처리, 크기 변경, DPI와 관련된 주요 창 메시지를 처리하고
  // 전달한다. 상속 클래스가 처리할 수 있도록 멤버 오버로드에 위임한다.
  virtual LRESULT MessageHandler(HWND window,
                                 UINT const message,
                                 WPARAM const wparam,
                                 LPARAM const lparam) noexcept;

  // CreateAndShow 호출 때 하위 클래스의 창 관련 설정을 허용한다.
  // 설정에 실패하면 하위 클래스는 false를 반환해야 한다.
  virtual bool OnCreate();

  // Destroy 호출 때 실행된다.
  virtual void OnDestroy();

 private:
  friend class WindowClassRegistrar;

  // 메시지 펌프가 호출하는 OS 콜백이다. 비클라이언트 영역이 생성될 때
  // 전달되는 WM_NCCREATE 메시지를 처리하고 자동 비클라이언트 DPI 배율을
  // 활성화해 해당 영역이 DPI 변경에 자동으로 반응하게 한다. 그 밖의
  // 메시지는 MessageHandler가 처리한다.
  static LRESULT CALLBACK WndProc(HWND const window,
                                  UINT const message,
                                  WPARAM const wparam,
                                  LPARAM const lparam) noexcept;

  // |window|의 클래스 인스턴스 포인터를 가져온다.
  static Win32Window* GetThisFromHandle(HWND const window) noexcept;

  // 시스템 테마에 맞게 창 프레임 테마를 갱신한다.
  static void UpdateTheme(HWND const window);

  bool quit_on_close_ = false;

  // 최상위 창의 창 핸들이다.
  HWND window_handle_ = nullptr;

  // 호스팅된 콘텐츠의 창 핸들이다.
  HWND child_content_ = nullptr;
};

#endif  // RUNNER_WIN32_WINDOW_H_
