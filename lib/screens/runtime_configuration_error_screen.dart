import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../state/app_state.dart';

/// 원격 백엔드를 설정할 수 없을 때 릴리스 빌드가 로컬 데모를 표시하지
/// 않도록 한다. 이 위젯은 일반 라우터/컨트롤러 트리를 만들기 전에
/// main.dart에서 연결한다.
class RuntimeConfigurationGate extends ConsumerWidget {
  const RuntimeConfigurationGate({required this.child, super.key});

  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final error = ref.watch(releaseConfigurationErrorProvider);
    if (error == null) return child;
    return MaterialApp(
      title: 'Moduly',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xff477b76)),
        useMaterial3: true,
      ),
      home: RuntimeConfigurationErrorScreen(message: error),
    );
  }
}

class RuntimeConfigurationErrorScreen extends StatelessWidget {
  const RuntimeConfigurationErrorScreen({required this.message, super.key});

  final String message;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 480),
              child: Card(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: <Widget>[
                      Icon(
                        Icons.cloud_off_outlined,
                        size: 56,
                        color: scheme.error,
                      ),
                      const SizedBox(height: 20),
                      Text(
                        '서비스를 시작할 수 없어요',
                        textAlign: TextAlign.center,
                        style: Theme.of(context).textTheme.headlineSmall
                            ?.copyWith(fontWeight: FontWeight.w700),
                      ),
                      const SizedBox(height: 12),
                      Text(
                        message,
                        textAlign: TextAlign.center,
                        style: Theme.of(context).textTheme.bodyLarge,
                      ),
                      const SizedBox(height: 20),
                      Text(
                        '운영 빌드는 Supabase 연결 없이는 데모 데이터로 전환하지 않습니다. '
                        '환경 변수와 배포 설정을 확인해 주세요.',
                        textAlign: TextAlign.center,
                        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
