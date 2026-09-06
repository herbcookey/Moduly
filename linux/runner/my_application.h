#ifndef FLUTTER_MY_APPLICATION_H_
#define FLUTTER_MY_APPLICATION_H_

#include <gtk/gtk.h>

G_DECLARE_FINAL_TYPE(MyApplication,
                     my_application,
                     MY,
                     APPLICATION,
                     GtkApplication)

/**
 * my_application_new:
 *
 * Flutter 기반 앱을 새로 만든다.
 *
 * 반환값: 새 #MyApplication이다.
 */
MyApplication* my_application_new();

#endif  // FLUTTER_MY_APPLICATION_H_
