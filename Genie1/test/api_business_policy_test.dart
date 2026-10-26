import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:homegenie/utils/api_business_policy.dart';

void main() {
  test(
    'field requirements, choices, defaults and numbers follow API metadata',
    () {
      final policy = ApiBusinessPolicy.fromApi({
        'fields': {
          'description': {'required': false, 'max_length': 3},
          'type': {
            'options': ['Server choice'],
          },
          'fixed': {'read_only': true, 'default': 'From ERP'},
          'amount': {'type': 'number', 'min_exclusive': 10},
        },
        'rules': {},
      });
      expect(policy.validate('description', '', legacyRequired: true), isNull);
      expect(policy.validate('description', 'long'), isNotNull);
      expect(policy.options('type', ['Old choice']), ['Server choice']);
      expect(policy.validate('type', 'Old choice'), isNotNull);
      expect(policy.validate('amount', 10), isNotNull);
      expect(policy.validate('amount', 11), isNull);
      final controller = TextEditingController(text: 'Client');
      policy.applyDefault('fixed', controller);
      expect(controller.text, 'From ERP');
      controller.dispose();
    },
  );

  test(
    'actions require a current API decision and preserve blocking reasons',
    () {
      final policy = ApiBusinessPolicy({
        'actions': {
          'check_in': {'allowed': false, 'reason': 'Attendance required'},
          'check_out': {'allowed': true, 'reason': ''},
          'prepare': {
            'allowed': false,
            'can_prepare': true,
            'reason': 'Attach files',
          },
        },
      });
      expect(policy.actionBlockReason('check_in'), 'Attendance required');
      expect(policy.actionBlockReason('check_out'), isNull);
      expect(policy.actionBlockReason('unknown'), isNotNull);
      expect(policy.actionBlockReason('prepare'), 'Attach files');
      expect(
        policy.actionBlockReason('prepare', allowPreparation: true),
        isNull,
      );
    },
  );

  test('upload formats, byte size and counts follow API settings', () async {
    final directory = await Directory.systemTemp.createTemp('policy_files_');
    try {
      final path = '${directory.path}/photo.jpg';
      await File(path).writeAsString('12345');
      final policy = ApiBusinessPolicy({
        'uploads': {
          'min_count': 1,
          'max_count': 1,
          'max_bytes': 5,
          'extensions': ['.jpg'],
        },
      });
      expect(await policy.validateUploads([path]), isNull);
      expect(await policy.validateUploads([]), isNotNull);
      expect(await policy.validateUploads([path, path]), isNotNull);
      expect(
        await policy.validateUploads(['${directory.path}/file.pdf']),
        isNotNull,
      );
      await File(path).writeAsString('123456');
      expect(await policy.validateUploads([path]), isNotNull);
      expect(
        await ApiBusinessPolicy({
          'uploads': {'min_count': 0},
        }).validateUploads([]),
        isNull,
      );
    } finally {
      await directory.delete(recursive: true);
    }
  });

  testWidgets('API field visibility and read-only settings control input', (
    tester,
  ) async {
    final policy = ApiBusinessPolicy.fromApi({
      'fields': {
        'hidden': {'visible': false},
        'fixed': {'read_only': true},
      },
      'rules': {},
    });
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Column(
            children: [
              BusinessPolicyField(
                policy: policy,
                name: 'hidden',
                child: const Text('Hidden field'),
              ),
              BusinessPolicyField(
                policy: policy,
                name: 'fixed',
                child: const TextField(),
              ),
            ],
          ),
        ),
      ),
    );
    expect(find.text('Hidden field'), findsNothing);
    final wrapper = tester.widget<AbsorbPointer>(
      find
          .ancestor(
            of: find.byType(TextField),
            matching: find.byType(AbsorbPointer),
          )
          .first,
    );
    expect(wrapper.absorbing, isTrue);
  });
}
