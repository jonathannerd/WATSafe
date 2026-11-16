class LocalRelaySupervisor {
  LocalRelaySupervisor({
    this.forceEnableForTest = false,
    this.storageDirectory,
  });

  final bool forceEnableForTest;
  final String? storageDirectory;

  bool get isRunningEmbeddedRelay => false;

  Future<String?> ensureRelayAvailable({
    required String currentEndpointUrl,
    int fallbackPort = 8787,
  }) async {
    return currentEndpointUrl;
  }

  Future<void> dispose() async {}
}
