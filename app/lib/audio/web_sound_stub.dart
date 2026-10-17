/// Not on the web: [Sfx] uses audioplayers instead.
class WebSound {
  WebSound();

  static bool get supported => false;

  Future<void> load(Iterable<String> files) async {}
  void play(String file, double volume) {}
  Future<void> loop(String channel, String? file, double volume) async {}
  void setLoopVolume(String channel, double volume) {}
  Future<void> setQuiet(bool quiet) async {}
  Future<void> close() async {}
}
