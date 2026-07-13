import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:friendify/screens/auth_screen.dart';

void main() {
  testWidgets('AuthScreen does not auto focus text fields on first build', (
    tester,
  ) async {
    await tester.pumpWidget(const MaterialApp(home: AuthScreen()));
    await tester.pump();

    final editableTexts =
        tester.widgetList<EditableText>(find.byType(EditableText)).toList();

    expect(editableTexts, isNotEmpty);
    expect(
      editableTexts.every((editable) => !editable.focusNode.hasFocus),
      isTrue,
    );
  });

  testWidgets('AuthScreen clears focus when switching auth mode', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(800, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(const MaterialApp(home: AuthScreen()));
    await tester.pump();

    final emailField = find.byType(TextField).first;
    await tester.ensureVisible(emailField);
    await tester.tap(emailField, warnIfMissed: false);
    await tester.showKeyboard(emailField);
    await tester.pump();

    var editableTexts =
        tester.widgetList<EditableText>(find.byType(EditableText)).toList();
    expect(
      editableTexts.any((editable) => editable.focusNode.hasFocus),
      isTrue,
    );

    final signUpButton = find.byKey(
      const ValueKey('auth_mode_signup_button'),
    );
    expect(signUpButton, findsOneWidget);
    await tester.ensureVisible(signUpButton);
    await tester.pumpAndSettle();
    await tester.tap(signUpButton);
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('auth_name_field')), findsOneWidget);

    editableTexts =
        tester.widgetList<EditableText>(find.byType(EditableText)).toList();
    expect(
      editableTexts.every((editable) => !editable.focusNode.hasFocus),
      isTrue,
    );
  });
}
