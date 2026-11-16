class LocalRelaySupervisor {
  LocalRelaySupervisor({this.forceEnableForTest = false});

  final bool forceEnableForTest;

  bool get isRunningEmbeddedRelay => false;

  Future<String?> ensureRelayAvailable({
    required String currentEndpointUrl,
    int fallbackPort = 8787,
  }) async {
    return currentEndpointUrl;
  }

  Future<void> dispose() async {}
}
