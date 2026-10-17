import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:wordsmith/data/profile.dart';
import 'package:wordsmith/features/coop/room_video.dart';
import 'package:wordsmith/net/api_client.dart';
import 'package:wordsmith/ui/widgets/video_bubble.dart';
import 'package:wordsmith/video/video_call.dart';

import '../fixtures/fake_video.dart';

Widget _wrap(Widget child) => MaterialApp(
  home: Scaffold(body: Center(child: child)),
);

void main() {
  testWidgets('a bubble shows live video while the camera is on, otherwise the avatar', (tester) async {
    final call = FakeVideoCall();
    await tester.pumpWidget(_wrap(VideoBubble(userId: 'u2', avatar: 'avatar_05', size: 48, call: call)));
    expect(find.byKey(const ValueKey('video-u2')), findsNothing);
    expect(find.byType(SvgPicture), findsOneWidget, reason: 'the avatar');

    call.peers = {'u2': const VideoPeer(id: 'u2', camera: true, mic: true)};
    await tester.pump();
    expect(find.byKey(const ValueKey('video-u2')), findsOneWidget);
    expect(find.byIcon(Icons.mic_off), findsNothing);

    call.peers = {'u2': const VideoPeer(id: 'u2', camera: true, mic: false)};
    await tester.pump();
    expect(find.byIcon(Icons.mic_off), findsOneWidget, reason: 'a muted mic is marked');

    call.peers = {'u2': const VideoPeer(id: 'u2', camera: false, mic: true)};
    await tester.pump();
    expect(find.byKey(const ValueKey('video-u2')), findsNothing);
  });

  testWidgets('my own bubble shows my camera, or my avatar marked as camera off', (tester) async {
    final call = FakeVideoCall(me: 'u1');
    await call.join(url: 'wss://x', token: 't', camera: true, mic: true);
    await tester.pumpWidget(_wrap(VideoBubble(userId: 'u1', avatar: 'avatar_05', size: 48, call: call, me: true)));
    expect(find.byKey(const ValueKey('video-u1')), findsOneWidget);
    expect(find.byIcon(Icons.videocam_off), findsNothing);

    await call.setCamera(false);
    await tester.pump();
    expect(find.byKey(const ValueKey('video-u1')), findsNothing);
    expect(find.byType(SvgPicture), findsOneWidget, reason: 'my avatar');
    expect(find.byIcon(Icons.videocam_off), findsOneWidget);

    // Someone else's camera being off isn't marked.
    await tester.pumpWidget(_wrap(VideoBubble(userId: 'u2', avatar: 'avatar_05', size: 48, call: call)));
    expect(find.byIcon(Icons.videocam_off), findsNothing);
  });

  testWidgets('without a call the bubble is just the avatar', (tester) async {
    await tester.pumpWidget(_wrap(const VideoBubble(userId: 'u2', avatar: 'avatar_05', size: 48)));
    expect(find.byType(SvgPicture), findsOneWidget);
  });

  testWidgets('the lobby video bar turns video on, then switches camera and mic', (tester) async {
    final taps = <String>[];
    RoomVideo video(VideoCall? call) => RoomVideo(
      available: true,
      call: call,
      onEnable: () => taps.add('enable'),
      onDisable: () => taps.add('disable'),
      onCamera: () => taps.add('camera'),
      onMic: () => taps.add('mic'),
    );

    await tester.pumpWidget(_wrap(VideoBar(video: video(null))));
    await tester.tap(find.text('Turn on video chat'));
    expect(taps, ['enable']);

    final call = FakeVideoCall();
    await call.join(url: 'wss://x', token: 't', camera: true, mic: false);
    await tester.pumpWidget(_wrap(VideoBar(video: video(call))));
    expect(find.text('Video chat on'), findsOneWidget);
    expect(find.byIcon(Icons.videocam), findsWidgets);
    expect(find.byIcon(Icons.mic_off), findsOneWidget);

    await tester.tap(find.byTooltip('Turn camera off'));
    await tester.tap(find.byTooltip('Unmute'));
    await tester.tap(find.text('Turn off'));
    expect(taps, ['enable', 'camera', 'mic', 'disable']);

    call
      ..error = "Couldn't use the camera."
      ..status = VideoStatus.failed;
    await tester.pump();
    expect(find.text('Video chat is off'), findsOneWidget);
    expect(find.text("Couldn't use the camera."), findsOneWidget);
  });

  testWidgets('builds without online play show no video bar', (tester) async {
    await tester.pumpWidget(_wrap(const VideoBar(video: RoomVideo.none)));
    expect(find.text('Turn on video chat'), findsNothing);
  });

  test('video settings are saved', () {
    final s = Settings.fromJson(const Settings().copyWith(videoChat: true, videoMic: false).toJson());
    expect((s.videoChat, s.videoCamera, s.videoMic), (true, true, false));
    final old = Settings.fromJson(const {'sfx': 0.5});
    expect((old.videoChat, old.videoCamera, old.videoMic), (false, true, true), reason: 'off until chosen');
  });

  test('the API hands out a room video token, or says video is not set up', () async {
    final requests = <String>[];
    var configured = true;
    final api = ApiClient(
      baseUrl: 'https://forge.test',
      token: () async => 'tok',
      client: MockClient((req) async {
        requests.add('${req.method} ${req.url.path}');
        return configured
            ? http.Response(jsonEncode({'url': 'wss://lk.test', 'token': 'jwt', 'room': 'r', 'expiresAt': 1}), 200)
            : http.Response(jsonEncode({'error': 'video_unavailable'}), 503);
      }),
    );
    final grant = await api.roomVideo('K7Q2AB');
    expect((grant.url, grant.token), ('wss://lk.test', 'jwt'));
    expect(requests.single, 'POST /v1/rooms/K7Q2AB/video');

    configured = false;
    await expectLater(
      api.roomVideo('K7Q2AB'),
      throwsA(isA<ApiException>().having((e) => e.friendly, 'friendly', "Video chat isn't set up on the server yet.")),
    );
  });
}
