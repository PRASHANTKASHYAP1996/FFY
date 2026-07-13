import 'package:flutter/animation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:friendify/shared/chat_navigation_guards.dart';

void main() {
  test('bootstrap mismatch is handled in UI instead of being rethrown', () {
    expect(
      shouldHandleDirectionMismatchInUi(
        directionMatchesRequested: false,
      ),
      isTrue,
    );
    expect(
      shouldHandleDirectionMismatchInUi(
        directionMatchesRequested: true,
      ),
      isFalse,
    );
  });

  test('listener profile opposite direction is detected as controlled state',
      () {
    expect(
      selectedListenerMatchesStoredDirection(
        selectedListenerId: 'listener-b',
        actualListenerId: 'listener-a',
      ),
      isFalse,
    );
    expect(
      selectedListenerMatchesStoredDirection(
        selectedListenerId: 'listener-b',
        actualListenerId: 'listener-b',
      ),
      isTrue,
    );
  });

  test('unsafe push direction does not navigate', () {
    expect(
      isSafeChatPushDirection(
        speakerId: 'speaker-1',
        listenerId: 'listener-1',
        actualListenerId: '',
        myUid: 'speaker-1',
      ),
      isFalse,
    );
    expect(
      isSafeChatPushDirection(
        speakerId: 'speaker-1',
        listenerId: 'listener-1',
        actualListenerId: 'listener-1',
        myUid: 'outsider',
      ),
      isFalse,
    );
    expect(
      isSafeChatPushDirection(
        speakerId: 'canonical-a',
        listenerId: 'canonical-z',
        actualListenerId: 'canonical-a',
        myUid: 'canonical-z',
      ),
      isFalse,
    );
  });

  test('failed bootstrap does not request composer visibility', () {
    expect(
      shouldShowChatComposerForBootstrap(
        bootstrapping: true,
        hasBootstrapError: false,
      ),
      isFalse,
    );
    expect(
      shouldShowChatComposerForBootstrap(
        bootstrapping: false,
        hasBootstrapError: true,
      ),
      isFalse,
    );
    expect(
      shouldShowChatComposerForBootstrap(
        bootstrapping: false,
        hasBootstrapError: false,
      ),
      isTrue,
    );
  });

  test('route transition stays active until push animation settles', () {
    expect(
      isChatRouteTransitionActive(
        navigatingAway: false,
        hasRoute: true,
        routeIsCurrent: true,
        primaryStatus: AnimationStatus.forward,
        secondaryStatus: AnimationStatus.dismissed,
      ),
      isTrue,
    );

    expect(
      isChatRouteTransitionActive(
        navigatingAway: false,
        hasRoute: true,
        routeIsCurrent: true,
        primaryStatus: AnimationStatus.completed,
        secondaryStatus: AnimationStatus.dismissed,
      ),
      isFalse,
    );

    expect(
      isChatRouteTransitionActive(
        navigatingAway: true,
        hasRoute: true,
        routeIsCurrent: true,
        primaryStatus: AnimationStatus.completed,
        secondaryStatus: AnimationStatus.dismissed,
      ),
      isTrue,
    );
  });
}
