import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wordsmith/video/call_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('wordsmith/call');
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  test('without the Android side the call service does nothing', () async {
    const service = CallService();
    await expectLater(service.start(mic: true), completes);
    await expectLater(service.start(mic: false), completes);
    await expectLater(service.stop(), completes);
  });

  test('it tells MainActivity about the call and the mic, and shrugs off its errors', () async {
    final calls = <String>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add('${call.method} ${call.arguments}');
      if (call.method == 'stop') throw PlatformException(code: 'oops');
      return null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));

    const service = CallService();
    await service.start(mic: true);
    await service.start(mic: false);
    await expectLater(service.stop(), completes);
    expect(calls, ['start {mic: true}', 'start {mic: false}', 'stop null']);
  });
}
