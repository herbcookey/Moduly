#include "my_application.h"

#include <flutter_linux/flutter_linux.h>
#ifdef GDK_WINDOWING_X11
#include <gdk/gdkx.h>
#endif

#include "flutter/generated_plugin_registrant.h"

struct _MyApplication {
  GtkApplication parent_instance;
  char** dart_entrypoint_arguments;
};

G_DEFINE_TYPE(MyApplication, my_application, GTK_TYPE_APPLICATION)

// 첫 Flutter 프레임을 받으면 호출된다.
static void first_frame_cb(MyApplication* self, FlView* view) {
  gtk_widget_show(gtk_widget_get_toplevel(GTK_WIDGET(view)));
}

// GApplication::activate를 구현한다.
static void my_application_activate(GApplication* application) {
  MyApplication* self = MY_APPLICATION(application);
  GtkWindow* window =
      GTK_WINDOW(gtk_application_window_new(GTK_APPLICATION(application)));

  // GNOME에서는 앱이 흔히 사용하는 구성이고 대부분의 사용자가 쓰므로
  // 헤더 바를 사용한다(예: Ubuntu 데스크톱).
  // X에서 GNOME을 사용하지 않으면 창 관리자가 타일링 같은 특수 배치를
  // 할 수 있으므로 전통적인 제목 표시줄을 사용한다.
  // Wayland에서는 헤더 바가 동작한다고 가정한다(향후 바꿀 수 있다).
  gboolean use_header_bar = TRUE;
#ifdef GDK_WINDOWING_X11
  GdkScreen* screen = gtk_window_get_screen(window);
  if (GDK_IS_X11_SCREEN(screen)) {
    const gchar* wm_name = gdk_x11_screen_get_window_manager_name(screen);
    if (g_strcmp0(wm_name, "GNOME Shell") != 0) {
      use_header_bar = FALSE;
    }
  }
#endif
  if (use_header_bar) {
    GtkHeaderBar* header_bar = GTK_HEADER_BAR(gtk_header_bar_new());
    gtk_widget_show(GTK_WIDGET(header_bar));
    gtk_header_bar_set_title(header_bar, "Moduly");
    gtk_header_bar_set_show_close_button(header_bar, TRUE);
    gtk_window_set_titlebar(window, GTK_WIDGET(header_bar));
  } else {
    gtk_window_set_title(window, "Moduly");
  }

  gtk_window_set_default_size(window, 1280, 720);

  g_autoptr(FlDartProject) project = fl_dart_project_new();
  fl_dart_project_set_dart_entrypoint_arguments(
      project, self->dart_entrypoint_arguments);

  FlView* view = fl_view_new(project);
  GdkRGBA background_color;
  // 배경 기본값은 검정이다. 필요하면 여기서 덮어쓴다. 예를 들어
  // 투명하게 하려면 #00000000을 사용한다.
  gdk_rgba_parse(&background_color, "#000000");
  fl_view_set_background_color(view, &background_color);
  gtk_widget_show(GTK_WIDGET(view));
  gtk_container_add(GTK_CONTAINER(window), GTK_WIDGET(view));

  // Flutter가 렌더링할 때 창을 표시한다.
  // 렌더링을 시작하려면 뷰가 실체화되어 있어야 한다.
  g_signal_connect_swapped(view, "first-frame", G_CALLBACK(first_frame_cb),
                           self);
  gtk_widget_realize(GTK_WIDGET(view));

  fl_register_plugins(FL_PLUGIN_REGISTRY(view));

  gtk_widget_grab_focus(GTK_WIDGET(view));
}

// GApplication::local_command_line을 구현한다.
static gboolean my_application_local_command_line(GApplication* application,
                                                  gchar*** arguments,
                                                  int* exit_status) {
  MyApplication* self = MY_APPLICATION(application);
  // 첫 번째 인수는 바이너리 이름이므로 제거한다.
  self->dart_entrypoint_arguments = g_strdupv(*arguments + 1);

  g_autoptr(GError) error = nullptr;
  if (!g_application_register(application, nullptr, &error)) {
    g_warning("등록하지 못했습니다: %s", error->message);
    *exit_status = 1;
    return TRUE;
  }

  g_application_activate(application);
  *exit_status = 0;

  // gtk의 애플리케이션 알림기가 명령줄 인수(사용자 지정 스킴 콜백 포함)를
  // app_links로 전달할 수 있도록 FALSE를 반환한다.
  return FALSE;
}

// GApplication::startup을 구현한다.
static void my_application_startup(GApplication* application) {
  // 사용하지 않는 예시: MyApplication* self = MY_APPLICATION(object);

  // 앱 시작에 필요한 작업을 수행한다.

  G_APPLICATION_CLASS(my_application_parent_class)->startup(application);
}

// GApplication::shutdown을 구현한다.
static void my_application_shutdown(GApplication* application) {
  // 사용하지 않는 예시: MyApplication* self = MY_APPLICATION(object);

  // 앱 종료에 필요한 작업을 수행한다.

  G_APPLICATION_CLASS(my_application_parent_class)->shutdown(application);
}

// GObject::dispose를 구현한다.
static void my_application_dispose(GObject* object) {
  MyApplication* self = MY_APPLICATION(object);
  g_clear_pointer(&self->dart_entrypoint_arguments, g_strfreev);
  G_OBJECT_CLASS(my_application_parent_class)->dispose(object);
}

static void my_application_class_init(MyApplicationClass* klass) {
  G_APPLICATION_CLASS(klass)->activate = my_application_activate;
  G_APPLICATION_CLASS(klass)->local_command_line =
      my_application_local_command_line;
  G_APPLICATION_CLASS(klass)->startup = my_application_startup;
  G_APPLICATION_CLASS(klass)->shutdown = my_application_shutdown;
  G_OBJECT_CLASS(klass)->dispose = my_application_dispose;
}

static void my_application_init(MyApplication* self) {}

MyApplication* my_application_new() {
  // 프로그램 이름을 앱 식별자로 설정한다. GTK와 데스크톱 환경이 실행 중인
  // 앱을 해당 .desktop 파일에 연결하는 데 도움이 된다. 바이너리 이름 외에도
  // 앱을 인식할 수 있어 시스템 통합이 좋아진다.
  g_set_prgname(APPLICATION_ID);

  return MY_APPLICATION(g_object_new(
      my_application_get_type(), "application-id", APPLICATION_ID, "flags",
      G_APPLICATION_HANDLES_COMMAND_LINE | G_APPLICATION_HANDLES_OPEN,
      nullptr));
}
