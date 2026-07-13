import 'package:flutter_test/flutter_test.dart';

import 'package:friendify/repositories/call_repository.dart';
import 'package:friendify/screens/chat_conversation_screen.dart';

void main() {
  test(
    'Chat bootstrap mismatch sets controlled error state, not uncaught exception',
    () {
      const strictResolution = ChatSessionDirectionResolution.success(
        participantIds: <String>['listener_a', 'speaker_b'],
        actualSpeakerId: 'speaker_b',
        actualListenerId: 'listener_a',
        otherUid: 'listener_a',
        iAmListener: false,
      );

      expect(
        () => decideChatBootstrapDirection(
          strictResolution: strictResolution,
          legacyResolution: const ChatSessionDirectionResolution.error(
            'not_needed',
          ),
          requestedSpeakerId: 'listener_a',
          requestedProductListenerId: 'speaker_b',
        ),
        returnsNormally,
      );

      final decision = decideChatBootstrapDirection(
        strictResolution: strictResolution,
        legacyResolution: const ChatSessionDirectionResolution.error(
          'not_needed',
        ),
        requestedSpeakerId: 'listener_a',
        requestedProductListenerId: 'speaker_b',
      );

      expect(decision.kind, ChatBootstrapDirectionDecisionKind.mismatch);
      expect(decision.handledInUi, isTrue);
      expect(
        decision.message,
        contains('Open the existing conversation or go back'),
      );
    },
  );

  test(
    'Chat bootstrap requires repair when strict direction is missing even if legacy direction matches',
    () {
      const legacyResolution = ChatSessionDirectionResolution.success(
        participantIds: <String>['listener_a', 'speaker_b'],
        actualSpeakerId: 'speaker_b',
        actualListenerId: 'listener_a',
        otherUid: 'listener_a',
        iAmListener: false,
      );

      final decision = decideChatBootstrapDirection(
        strictResolution: const ChatSessionDirectionResolution.error(
          'actualListenerId is missing or unsafe',
        ),
        legacyResolution: legacyResolution,
        requestedSpeakerId: 'speaker_b',
        requestedProductListenerId: 'listener_a',
      );

      expect(decision.kind, ChatBootstrapDirectionDecisionKind.needsRepair);
      expect(decision.handledInUi, isTrue);
      expect(decision.message, contains('needs repair'));
    },
  );
}
