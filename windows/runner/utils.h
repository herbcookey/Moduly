#ifndef RUNNER_UTILS_H_
#define RUNNER_UTILS_H_

#include <string>
#include <vector>

// 프로세스용 콘솔을 만들고 runner와 Flutter 라이브러리의 stdout/stderr를
// 해당 콘솔로 리디렉션한다.
void CreateAndAttachConsole();

// UTF-16으로 인코딩된 널 종료 wchar_t*를 받아 UTF-8로 인코딩된
// std::string을 반환한다. 실패하면 빈 std::string을 반환한다.
std::string Utf8FromUtf16(const wchar_t* utf16_string);

// 전달된 명령줄 인수를 UTF-8로 인코딩된 std::vector<std::string>으로
// 가져온다. 실패하면 빈 std::vector<std::string>을 반환한다.
std::vector<std::string> GetCommandLineArguments();

#endif  // RUNNER_UTILS_H_
