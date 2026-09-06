import 'package:flutter/material.dart';

import '../legal/legal_documents.dart';

class PrivacyPolicyScreen extends StatelessWidget {
  const PrivacyPolicyScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return const LegalDocumentScreen(
      title: '개인정보처리방침',
      sections: privacyPolicySections,
    );
  }
}

class TermsOfServiceScreen extends StatelessWidget {
  const TermsOfServiceScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return const LegalDocumentScreen(
      title: '이용약관',
      sections: termsOfServiceSections,
    );
  }
}

class LegalDocumentScreen extends StatelessWidget {
  const LegalDocumentScreen({
    required this.title,
    required this.sections,
    super.key,
  });

  final String title;
  final List<LegalSection> sections;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: Text(title)),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 20, 20, 40),
        children: <Widget>[
          Text(
            'Moduly · $legalDocumentEffectiveDate',
            style: textTheme.labelMedium?.copyWith(color: scheme.outline),
          ),
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: scheme.secondaryContainer,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Text(
              '현재 저장소와 배포 전 확인 사항을 바탕으로 한 초안입니다. 실제 운영자 정보와 연락처는 공개 전에 운영자가 확인해 반영해야 하며, 이 문서는 법률 자문이 아닙니다.',
              style: textTheme.bodyMedium?.copyWith(
                color: scheme.onSecondaryContainer,
                height: 1.45,
              ),
            ),
          ),
          const SizedBox(height: 20),
          for (final section in sections) ...<Widget>[
            Text(
              section.heading,
              style: textTheme.titleMedium?.copyWith(
                color: scheme.primary,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 8),
            SelectableText(
              section.body,
              style: textTheme.bodyMedium?.copyWith(height: 1.55),
            ),
            const SizedBox(height: 22),
          ],
        ],
      ),
    );
  }
}
