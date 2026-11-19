import 'dart:math' as math;
import 'dart:typed_data';

/// Raw uncompressed video pixel formats supported by [CameraFrameSampler].
enum CameraPixelFormat {
  /// 8-bit Y plane followed by interleaved UV plane (`MFVideoFormat_NV12`).
  nv12,

  /// 8-bit Y plane followed by U and V planes (`MFVideoFormat_I420` / `IYUV`).
  i420,

  /// Packed 4:2:2 `Y0 U0 Y1 V0` (`MFVideoFormat_YUY2`, 2 bytes/pixel).
  yuy2,

  /// Packed 4:2:2 `U0 Y0 V0 Y1` (`MFVideoFormat_UYVY`, 2 bytes/pixel).
  uyvy,

  /// 32-bit `B G R A` / `B G R X` (`MFVideoFormat_RGB32`, `ARGB32`, macOS `32BGRA`).
  bgra32,

  /// 32-bit `R G B A` (HTML5 `CanvasRenderingContext2D.getImageData`).
  rgba32,

  /// 24-bit `B G R` (`MFVideoFormat_RGB24`).
  bgr24,
}

/// Result of downsampling a raw camera frame to a compact grayscale grid.
class SampledGrayscaleFrame {
  const SampledGrayscaleFrame({
    required this.grid,
    required this.width,
    required this.height,
    required this.meanLuminance255,
    required this.normalizedDeviation,
    required this.effectiveRowStride,
  });

  final Float32List grid;
  final int width;
  final int height;
  final double meanLuminance255;
  final double normalizedDeviation;
  final int effectiveRowStride;

  double get normalizedLuminance => meanLuminance255 / 255.0;
}

/// Downsamples raw camera buffers into compact grayscale grids while handling
/// Media Foundation / AVFoundation / Web row strides, contiguous unpadded
/// copies, and negative bottom-up DIB strides.
class CameraFrameSampler {
  const CameraFrameSampler._();

  /// Minimum unpadded byte width of one luma/RGB row for [format].
  static int minimumRowStride(CameraPixelFormat format, int srcWidth) {
    switch (format) {
      case CameraPixelFormat.nv12:
      case CameraPixelFormat.i420:
        return srcWidth;
      case CameraPixelFormat.yuy2:
      case CameraPixelFormat.uyvy:
        return srcWidth * 2;
      case CameraPixelFormat.bgr24:
        return srcWidth * 3;
      case CameraPixelFormat.bgra32:
      case CameraPixelFormat.rgba32:
        return srcWidth * 4;
    }
  }

  /// Expected total byte size of a tightly-packed contiguous frame (such as
  /// Media Foundation `IMF2DBuffer::ContiguousCopyTo` output).
  static int contiguousFrameByteLength(
    CameraPixelFormat format,
    int srcWidth,
    int srcHeight,
  ) {
    switch (format) {
      case CameraPixelFormat.nv12:
      case CameraPixelFormat.i420:
        final uvWidth = (srcWidth + 1) >> 1;
        final uvHeight = (srcHeight + 1) >> 1;
        return (srcWidth * srcHeight) + (uvWidth * uvHeight * 2);
      case CameraPixelFormat.yuy2:
      case CameraPixelFormat.uyvy:
      case CameraPixelFormat.bgr24:
      case CameraPixelFormat.bgra32:
      case CameraPixelFormat.rgba32:
        return minimumRowStride(format, srcWidth) * srcHeight;
    }
  }

  /// Resolves the actual row pitch (in bytes) of [bufferLength] when the stream
  /// media type reported [reportedStride].
  ///
  /// When `IMF2DBuffer::ConvertToContiguousBuffer` (`isContiguousBuffer: true`)
  /// strips row padding, `MF_MT_DEFAULT_STRIDE` still reports the GPU surface's
  /// padded pitch (e.g. `768` for `640`-wide NV12 or `2688` for `640`-wide
  /// RGB32). Using the padded stride on a contiguous buffer either rejects all
  /// frames (`bufferLength < absStride * srcHeight`) or skews rows into the UV
  /// chroma plane. This method resolves the true row stride safely.
  static int? resolveEffectiveRowStride({
    required int bufferLength,
    required CameraPixelFormat format,
    required int srcWidth,
    required int srcHeight,
    required int reportedStride,
    bool isContiguousBuffer = false,
  }) {
    if (srcWidth <= 0 || srcHeight <= 0) {
      return null;
    }
    final minStride = minimumRowStride(format, srcWidth);
    final minRequiredLumaBytes = minStride * srcHeight;
    if (bufferLength < minRequiredLumaBytes) {
      return null;
    }

    final absReported = reportedStride == 0 ? minStride : reportedStride.abs();
    if (isContiguousBuffer) {
      return minStride;
    }

    if (absReported < minStride) {
      return minStride;
    }

    final contiguousBytes = contiguousFrameByteLength(
      format,
      srcWidth,
      srcHeight,
    );
    if (absReported > minStride) {
      // If the buffer is smaller than padded luma height, or matches the exact
      // stripped contiguous frame size, its rows are packed at minStride.
      if (bufferLength < absReported * srcHeight ||
          bufferLength == contiguousBytes) {
        return minStride;
      }
    }

    return absReported;
  }

  /// Downsamples [rawBytes] into a `gridWidth x gridHeight` grayscale grid.
  static SampledGrayscaleFrame? sampleToGrayscaleGrid({
    required List<int> rawBytes,
    required CameraPixelFormat format,
    required int srcWidth,
    required int srcHeight,
    required int reportedStride,
    int gridWidth = 64,
    int gridHeight = 48,
    bool isContiguousBuffer = false,
  }) {
    if (rawBytes.isEmpty ||
        srcWidth <= 0 ||
        srcHeight <= 0 ||
        gridWidth <= 0 ||
        gridHeight <= 0) {
      return null;
    }

    final effectiveStride = resolveEffectiveRowStride(
      bufferLength: rawBytes.length,
      format: format,
      srcWidth: srcWidth,
      srcHeight: srcHeight,
      reportedStride: reportedStride,
      isContiguousBuffer: isContiguousBuffer,
    );
    if (effectiveStride == null) {
      return null;
    }

    final bottomUp =
        reportedStride < 0 &&
        (format == CameraPixelFormat.bgra32 ||
            format == CameraPixelFormat.rgba32 ||
            format == CameraPixelFormat.bgr24);

    final count = gridWidth * gridHeight;
    final grid = Float32List(count);
    var lumSum = 0.0;

    for (var gy = 0; gy < gridHeight; gy++) {
      var sy = (gy * srcHeight) ~/ gridHeight;
      if (bottomUp) {
        sy = (srcHeight - 1) - sy;
      }
      final rowOffset = sy * effectiveStride;

      for (var gx = 0; gx < gridWidth; gx++) {
        final sx = (gx * srcWidth) ~/ gridWidth;
        var yVal = 0.0;

        switch (format) {
          case CameraPixelFormat.nv12:
          case CameraPixelFormat.i420:
            final offset = rowOffset + sx;
            if (offset < rawBytes.length) {
              yVal = rawBytes[offset].toDouble();
            }
          case CameraPixelFormat.yuy2:
            final offset = rowOffset + (sx * 2);
            if (offset < rawBytes.length) {
              yVal = rawBytes[offset].toDouble();
            }
          case CameraPixelFormat.uyvy:
            final offset = rowOffset + (sx * 2) + 1;
            if (offset < rawBytes.length) {
              yVal = rawBytes[offset].toDouble();
            }
          case CameraPixelFormat.bgra32:
            final offset = rowOffset + (sx * 4);
            if (offset + 2 < rawBytes.length) {
              final b = rawBytes[offset];
              final g = rawBytes[offset + 1];
              final r = rawBytes[offset + 2];
              yVal = ((77 * r + 150 * g + 29 * b) >> 8).toDouble();
            }
          case CameraPixelFormat.rgba32:
            final offset = rowOffset + (sx * 4);
            if (offset + 2 < rawBytes.length) {
              final r = rawBytes[offset];
              final g = rawBytes[offset + 1];
              final b = rawBytes[offset + 2];
              yVal = ((77 * r + 150 * g + 29 * b) >> 8).toDouble();
            }
          case CameraPixelFormat.bgr24:
            final offset = rowOffset + (sx * 3);
            if (offset + 2 < rawBytes.length) {
              final b = rawBytes[offset];
              final g = rawBytes[offset + 1];
              final r = rawBytes[offset + 2];
              yVal = ((77 * r + 150 * g + 29 * b) >> 8).toDouble();
            }
        }

        final idx = gy * gridWidth + gx;
        grid[idx] = yVal;
        lumSum += yVal;
      }
    }

    final meanLum255 = lumSum / count;
    var devSum = 0.0;
    for (var i = 0; i < count; i++) {
      devSum += (grid[i] - meanLum255).abs();
    }
    final normalizedDeviation = (devSum / count) / 255.0;

    return SampledGrayscaleFrame(
      grid: grid,
      width: gridWidth,
      height: gridHeight,
      meanLuminance255: meanLum255,
      normalizedDeviation: normalizedDeviation,
      effectiveRowStride: effectiveStride,
    );
  }
}

/// Evaluation outcome of a single grayscale frame by [CameraMotionAnalyzer].
class CameraMotionFrameEvaluation {
  const CameraMotionFrameEvaluation({
    required this.isCalibrating,
    required this.calibrationJustCompleted,
    required this.isPoorInput,
    required this.poorInputJustChanged,
    required this.isLightingTransient,
    required this.motionScore,
    required this.rawSceneScore,
    required this.threshold,
    required this.normalizedLuminance,
    required this.consecutiveAboveThreshold,
    required this.triggered,
    required this.texturedReferenceBlocks,
    required this.anchoredTexturedBlocks,
    required this.activeQuadrants,
    required this.coherentTranslatedBlocks,
    this.slowDriftScore = 0.0,
    this.rigidCoherence = 0.0,
    this.loomingRejected = false,
    this.oscillationRejected = false,
    this.cameraObstructed = false,
    this.obstructionJustTriggered = false,
    this.obstructionKind,
    this.isObstructedAtCalibration = false,
    this.consecutiveObstructedFrames = 0,
  });

  final bool isCalibrating;
  final bool calibrationJustCompleted;
  final bool isPoorInput;
  final bool poorInputJustChanged;
  final bool isLightingTransient;
  final double motionScore;
  final double rawSceneScore;
  final double threshold;
  final double normalizedLuminance;
  final int consecutiveAboveThreshold;
  final bool triggered;
  final int texturedReferenceBlocks;
  final int anchoredTexturedBlocks;
  final int activeQuadrants;
  final int coherentTranslatedBlocks;
  final double slowDriftScore;
  final double rigidCoherence;
  final bool loomingRejected;
  final bool oscillationRejected;

  /// True when sustained loss of usable camera visibility (palm/hand against
  /// lens, dark/opaque cover, or bright washout/glare) has met the confirmation
  /// window after an unobstructed armed baseline was established.
  final bool cameraObstructed;

  /// True on the exact confirmation frame when [cameraObstructed] transitions
  /// from `false` to `true`.
  final bool obstructionJustTriggered;

  /// Active or candidate obstruction classification (`dark`, `bright_glare`,
  /// `opaque_cover`, or `texture_collapse`).
  final String? obstructionKind;

  /// True when the camera was already blocked or pitch-dark at the moment
  /// startup calibration completed.
  final bool isObstructedAtCalibration;

  /// Consecutive post-calibration frames matching an obstruction signature.
  final int consecutiveObstructedFrames;
}

class _FlowCoherenceStats {
  const _FlowCoherenceStats({
    required this.coherentCount,
    required this.panCoherence,
    required this.rollCoherence,
    required this.rigidCoherence,
    required this.radialDivergence,
    required this.meanDx,
    required this.meanDy,
    required this.isLooming,
  });

  static const empty = _FlowCoherenceStats(
    coherentCount: 0,
    panCoherence: 0.0,
    rollCoherence: 0.0,
    rigidCoherence: 0.0,
    radialDivergence: 0.0,
    meanDx: 0.0,
    meanDy: 0.0,
    isLooming: false,
  );

  final int coherentCount;
  final double panCoherence;
  final double rollCoherence;
  final double rigidCoherence;
  final double radialDivergence;
  final double meanDx;
  final double meanDy;
  final bool isLooming;
}

/// Stateful camera ego-motion estimator using Lucas-Kanade 2x2 optical flow,
/// coarse block displacement matching, static background/perimeter landmark
/// anchoring, radial looming rejection, hinge-oscillation filtering, rolling
/// multi-frame slow-drift consensus, and affine illumination normalization.
///
/// Distinguishes physical laptop movement (lifting, tilting, carrying away,
/// and slow sliding) from scene motion (people walking past, approaching or
/// leaning toward the camera, brief hand passes, seated occupancy, lighting
/// and auto-exposure shifts, and brief single desk bumps).
class CameraMotionAnalyzer {
  CameraMotionAnalyzer({
    this.gridWidth = 64,
    this.gridHeight = 48,
    this.calibrationDuration = const Duration(milliseconds: 1500),
    this.persistenceFramesRequired = 3,
    this.obstructionConfirmationFrames = defaultObstructionConfirmationFrames,
    double motionThreshold = 0.095,
  }) : _motionThreshold = motionThreshold.clamp(0.02, 0.50);

  /// Documented confirmation window (`10` frames ≈ `1.25s` at 8 fps) before a
  /// covered/washed-out webcam fires a tamper alarm, preventing brief hand waves
  /// (`2–6` frames) or single dropped/glare frames from false-alarming.
  static const int defaultObstructionConfirmationFrames = 10;

  static const int _blocksX = 4;
  static const int _blocksY = 4;
  static const int _totalBlocks = _blocksX * _blocksY;
  static const int _driftWindowFrames = 4;

  final int gridWidth;
  final int gridHeight;
  final Duration calibrationDuration;
  final int persistenceFramesRequired;
  final int obstructionConfirmationFrames;

  double _motionThreshold;
  Float32List? _referenceGrid;
  Float32List? _previousGrid;
  final List<Float32List> _recentGrids = <Float32List>[];
  final Int32List _settledBlockStreak = Int32List(_totalBlocks);
  double _previousMean255 = 0.0;
  double _prevMeanFlowDx = 0.0;
  double _prevMeanFlowDy = 0.0;
  bool _hasPrevMeanFlow = false;
  DateTime? _calibrationStart;
  bool _isCalibrationDone = false;
  bool _isInputDegraded = false;
  bool _isCameraObstructed = false;
  bool _isObstructedAtCalibration = false;
  bool _wasUnobstructedDuringSession = false;
  String? _lastObstructionKind;
  int _baselineTexturedBlocks = 0;
  double _baselineMeanGrad = 0.0;
  int _processedFrames = 0;
  int _consecutiveAboveThreshold = 0;
  int _consecutivePoorInputFrames = 0;
  int _consecutiveObstructedFrames = 0;
  int _unobstructedFrameStreak = 0;

  double get motionThreshold => _motionThreshold;
  bool get isCalibrationDone => _isCalibrationDone;
  bool get isInputDegraded => _isInputDegraded;
  bool get isCameraObstructed => _isCameraObstructed;
  bool get isObstructedAtCalibration => _isObstructedAtCalibration;
  int get consecutiveAboveThreshold => _consecutiveAboveThreshold;
  int get consecutiveObstructedFrames => _consecutiveObstructedFrames;

  void updateThreshold(double threshold) {
    _motionThreshold = threshold.clamp(0.02, 0.50);
    _consecutiveAboveThreshold = 0;
  }

  void reset() {
    _referenceGrid = null;
    _previousGrid = null;
    _recentGrids.clear();
    _settledBlockStreak.fillRange(0, _totalBlocks, 0);
    _previousMean255 = 0.0;
    _prevMeanFlowDx = 0.0;
    _prevMeanFlowDy = 0.0;
    _hasPrevMeanFlow = false;
    _calibrationStart = null;
    _isCalibrationDone = false;
    _isInputDegraded = false;
    _isCameraObstructed = false;
    _isObstructedAtCalibration = false;
    _wasUnobstructedDuringSession = false;
    _lastObstructionKind = null;
    _baselineTexturedBlocks = 0;
    _baselineMeanGrad = 0.0;
    _processedFrames = 0;
    _consecutiveAboveThreshold = 0;
    _consecutivePoorInputFrames = 0;
    _consecutiveObstructedFrames = 0;
    _unobstructedFrameStreak = 0;
  }

  void _captureBaselineTextureProfile(Float32List grid) {
    final blockGradSum = Float64List(_totalBlocks);
    final blockGradCount = Int32List(_totalBlocks);
    for (var gy = 0; gy + 1 < gridHeight; gy++) {
      final by = math.min(_blocksY - 1, (gy * _blocksY) ~/ gridHeight);
      for (var gx = 0; gx + 1 < gridWidth; gx++) {
        final bx = math.min(_blocksX - 1, (gx * _blocksX) ~/ gridWidth);
        final bIdx = by * _blocksX + bx;
        final i = gy * gridWidth + gx;
        final v = grid[i];
        final gxDiff = (v - grid[i + 1]).abs();
        final gyDiff = (v - grid[i + gridWidth]).abs();
        blockGradSum[bIdx] += 0.5 * (gxDiff + gyDiff);
        blockGradCount[bIdx] += 1;
      }
    }
    var textured = 0;
    var gradSumAll = 0.0;
    var activeBlocks = 0;
    for (var b = 0; b < _totalBlocks; b++) {
      if (blockGradCount[b] <= 0) {
        continue;
      }
      final g = blockGradSum[b] / blockGradCount[b];
      gradSumAll += g;
      activeBlocks += 1;
      if (g >= 3.2) {
        textured += 1;
      }
    }
    _baselineTexturedBlocks = textured;
    _baselineMeanGrad = activeBlocks > 0 ? (gradSumAll / activeBlocks) : 0.0;
  }

  String? _classifyBaselineObstruction({
    required double normalizedLuminance,
    required double normalizedDeviation,
  }) {
    if (normalizedLuminance < 0.032) {
      return 'dark';
    }
    if (normalizedLuminance > 0.92 &&
        normalizedDeviation < 0.065 &&
        _baselineTexturedBlocks <= 1) {
      return 'bright_glare';
    }
    if (normalizedDeviation < 0.012 && _baselineTexturedBlocks == 0) {
      return 'opaque_cover';
    }
    return null;
  }

  /// Processes a downsampled `gridWidth x gridHeight` grayscale frame (`0..255`).
  CameraMotionFrameEvaluation processFrame(
    Float32List currentGrid, {
    required DateTime timestamp,
  }) {
    final count = gridWidth * gridHeight;
    if (currentGrid.length != count) {
      throw ArgumentError(
        'Expected grayscale grid of length $count (${gridWidth}x$gridHeight), got ${currentGrid.length}.',
      );
    }

    var lumSum = 0.0;
    for (var i = 0; i < count; i++) {
      lumSum += currentGrid[i];
    }
    final currMean = lumSum / count;
    final normalizedLuminance = currMean / 255.0;

    var currDevSum = 0.0;
    for (var i = 0; i < count; i++) {
      currDevSum += (currentGrid[i] - currMean).abs();
    }
    final currMad = currDevSum / count;
    final normalizedDeviation = currMad / 255.0;

    _processedFrames += 1;

    // 1. Check for pitch-black / covered lens degraded input.
    //    Darkness or a covered lens is reported honestly as degraded input and
    //    never silently equated with confirmed device theft.
    var poorInputJustChanged = false;
    if (normalizedLuminance < 0.025 || normalizedDeviation < 0.007) {
      _consecutivePoorInputFrames += 1;
      if (_consecutivePoorInputFrames >= 8 && !_isInputDegraded) {
        _isInputDegraded = true;
        poorInputJustChanged = true;
      }
    } else if (normalizedLuminance >= 0.04 && normalizedDeviation >= 0.012) {
      _consecutivePoorInputFrames = 0;
      if (_isInputDegraded) {
        _isInputDegraded = false;
        poorInputJustChanged = true;
      }
    }

    // 2. Startup baseline calibration.
    if (_referenceGrid == null) {
      _referenceGrid = Float32List.fromList(currentGrid);
      _previousGrid = Float32List.fromList(currentGrid);
      _previousMean255 = currMean;
      _calibrationStart = timestamp;
      return CameraMotionFrameEvaluation(
        isCalibrating: true,
        calibrationJustCompleted: false,
        isPoorInput: _isInputDegraded,
        poorInputJustChanged: poorInputJustChanged,
        isLightingTransient: false,
        motionScore: 0.0,
        rawSceneScore: 0.0,
        threshold: _motionThreshold,
        normalizedLuminance: normalizedLuminance,
        consecutiveAboveThreshold: 0,
        triggered: false,
        texturedReferenceBlocks: 0,
        anchoredTexturedBlocks: 0,
        activeQuadrants: 0,
        coherentTranslatedBlocks: 0,
      );
    }

    final reference = _referenceGrid!;
    final previous = _previousGrid!;

    if (!_isCalibrationDone) {
      for (var i = 0; i < count; i++) {
        reference[i] = (0.65 * reference[i]) + (0.35 * currentGrid[i]);
        previous[i] = currentGrid[i];
      }
      _previousMean255 = currMean;
      final elapsed = timestamp.difference(_calibrationStart ?? timestamp);
      if (elapsed >= calibrationDuration && _processedFrames >= 4) {
        _isCalibrationDone = true;
        _captureBaselineTextureProfile(reference);
        final initialObstruction = _classifyBaselineObstruction(
          normalizedLuminance: normalizedLuminance,
          normalizedDeviation: normalizedDeviation,
        );
        if (initialObstruction != null) {
          _isObstructedAtCalibration = true;
          _wasUnobstructedDuringSession = false;
          _lastObstructionKind = initialObstruction;
          if (!_isInputDegraded) {
            _isInputDegraded = true;
            poorInputJustChanged = true;
          }
        } else {
          _isObstructedAtCalibration = false;
          _wasUnobstructedDuringSession = true;
          _lastObstructionKind = null;
        }
        _recentGrids
          ..clear()
          ..add(Float32List.fromList(reference));
        return CameraMotionFrameEvaluation(
          isCalibrating: false,
          calibrationJustCompleted: true,
          isPoorInput: _isInputDegraded,
          poorInputJustChanged: poorInputJustChanged,
          isLightingTransient: false,
          motionScore: 0.0,
          rawSceneScore: 0.0,
          threshold: _motionThreshold,
          normalizedLuminance: normalizedLuminance,
          consecutiveAboveThreshold: 0,
          triggered: false,
          texturedReferenceBlocks: _baselineTexturedBlocks,
          anchoredTexturedBlocks: 0,
          activeQuadrants: 0,
          coherentTranslatedBlocks: 0,
          obstructionKind: _lastObstructionKind,
          isObstructedAtCalibration: _isObstructedAtCalibration,
        );
      }
      return CameraMotionFrameEvaluation(
        isCalibrating: true,
        calibrationJustCompleted: false,
        isPoorInput: _isInputDegraded,
        poorInputJustChanged: poorInputJustChanged,
        isLightingTransient: false,
        motionScore: 0.0,
        rawSceneScore: 0.0,
        threshold: _motionThreshold,
        normalizedLuminance: normalizedLuminance,
        consecutiveAboveThreshold: 0,
        triggered: false,
        texturedReferenceBlocks: 0,
        anchoredTexturedBlocks: 0,
        activeQuadrants: 0,
        coherentTranslatedBlocks: 0,
      );
    }

    final windowGrid = _recentGrids.isNotEmpty ? _recentGrids.first : previous;

    // 3. Per-block zero-mean & affine illumination normalization against BOTH
    //    the stationary reference AND the previous/window frames so foreground
    //    clothing, webcam auto-exposure gain ramps, and screen reflections
    //    cancel cleanly without corrupting unoccluded background anchors.
    final blockCurrSum = Float64List(_totalBlocks);
    final blockRefSum = Float64List(_totalBlocks);
    final blockPrevSum = Float64List(_totalBlocks);
    final blockWinSum = Float64List(_totalBlocks);
    final blockPixelCount = Int32List(_totalBlocks);

    var rawDiffSum = 0.0;
    for (var gy = 0; gy < gridHeight; gy++) {
      final by = math.min(_blocksY - 1, (gy * _blocksY) ~/ gridHeight);
      for (var gx = 0; gx < gridWidth; gx++) {
        final bx = math.min(_blocksX - 1, (gx * _blocksX) ~/ gridWidth);
        final bIdx = by * _blocksX + bx;
        final i = gy * gridWidth + gx;
        blockCurrSum[bIdx] += currentGrid[i];
        blockRefSum[bIdx] += reference[i];
        blockPrevSum[bIdx] += previous[i];
        blockWinSum[bIdx] += windowGrid[i];
        blockPixelCount[bIdx] += 1;
        rawDiffSum += (currentGrid[i] - reference[i]).abs();
      }
    }

    final blockCurrMean = Float64List(_totalBlocks);
    final blockRefMean = Float64List(_totalBlocks);
    final blockPrevMean = Float64List(_totalBlocks);
    final blockWinMean = Float64List(_totalBlocks);
    for (var b = 0; b < _totalBlocks; b++) {
      final n = blockPixelCount[b];
      if (n > 0) {
        blockCurrMean[b] = blockCurrSum[b] / n;
        blockRefMean[b] = blockRefSum[b] / n;
        blockPrevMean[b] = blockPrevSum[b] / n;
        blockWinMean[b] = blockWinSum[b] / n;
      }
    }

    final blockCurrDevSum = Float64List(_totalBlocks);
    final blockRefDevSum = Float64List(_totalBlocks);
    final blockPrevDevSum = Float64List(_totalBlocks);
    for (var gy = 0; gy < gridHeight; gy++) {
      final by = math.min(_blocksY - 1, (gy * _blocksY) ~/ gridHeight);
      for (var gx = 0; gx < gridWidth; gx++) {
        final bx = math.min(_blocksX - 1, (gx * _blocksX) ~/ gridWidth);
        final bIdx = by * _blocksX + bx;
        final i = gy * gridWidth + gx;
        blockCurrDevSum[bIdx] += (currentGrid[i] - blockCurrMean[bIdx]).abs();
        blockRefDevSum[bIdx] += (reference[i] - blockRefMean[bIdx]).abs();
        blockPrevDevSum[bIdx] += (previous[i] - blockPrevMean[bIdx]).abs();
      }
    }

    final blockGainToRef = Float64List(_totalBlocks);
    final blockGainToPrev = Float64List(_totalBlocks);
    for (var b = 0; b < _totalBlocks; b++) {
      final n = blockPixelCount[b];
      if (n <= 0) {
        blockGainToRef[b] = 1.0;
        blockGainToPrev[b] = 1.0;
        continue;
      }
      final cMad = blockCurrDevSum[b] / n;
      final rMad = blockRefDevSum[b] / n;
      final pMad = blockPrevDevSum[b] / n;
      blockGainToRef[b] = (cMad > 2.5 && rMad > 2.5)
          ? (rMad / cMad).clamp(0.66, 1.50)
          : 1.0;
      blockGainToPrev[b] = (cMad > 2.5 && pMad > 2.5)
          ? (pMad / cMad).clamp(0.74, 1.35)
          : 1.0;
    }

    final blockRefDiffSum = Float64List(_totalBlocks);
    final blockStepDiffSum = Float64List(_totalBlocks);
    final blockWinDiffSum = Float64List(_totalBlocks);
    final blockRefGradSum = Float64List(_totalBlocks);
    final blockCurrGradSum = Float64List(_totalBlocks);
    final blockGradCount = Int32List(_totalBlocks);

    var normRefDiffSum = 0.0;
    var normStepDiffSum = 0.0;

    for (var gy = 0; gy < gridHeight; gy++) {
      final by = math.min(_blocksY - 1, (gy * _blocksY) ~/ gridHeight);
      for (var gx = 0; gx < gridWidth; gx++) {
        final bx = math.min(_blocksX - 1, (gx * _blocksX) ~/ gridWidth);
        final bIdx = by * _blocksX + bx;
        final i = gy * gridWidth + gx;

        final currVal = currentGrid[i];
        final refVal = reference[i];
        final prevVal = previous[i];
        final winVal = windowGrid[i];

        final normCurrToRef =
            (currVal - blockCurrMean[bIdx]) * blockGainToRef[bIdx];
        final refCentered = refVal - blockRefMean[bIdx];
        final refDelta = (normCurrToRef - refCentered).abs();

        final normCurrToPrev =
            (currVal - blockCurrMean[bIdx]) * blockGainToPrev[bIdx];
        final prevCentered = prevVal - blockPrevMean[bIdx];
        final stepDelta = (normCurrToPrev - prevCentered).abs();

        final winShift = blockCurrMean[bIdx] - blockWinMean[bIdx];
        final winDelta = ((currVal - winVal) - winShift).abs();

        normRefDiffSum += refDelta;
        normStepDiffSum += stepDelta;
        blockRefDiffSum[bIdx] += refDelta;
        blockStepDiffSum[bIdx] += stepDelta;
        blockWinDiffSum[bIdx] += winDelta;

        if (gx + 1 < gridWidth && gy + 1 < gridHeight) {
          final gxDiff = (refVal - reference[i + 1]).abs();
          final gyDiff = (refVal - reference[i + gridWidth]).abs();
          blockRefGradSum[bIdx] += 0.5 * (gxDiff + gyDiff);

          final cgxDiff = (currVal - currentGrid[i + 1]).abs();
          final cgyDiff = (currVal - currentGrid[i + gridWidth]).abs();
          blockCurrGradSum[bIdx] += 0.5 * (cgxDiff + cgyDiff);
          blockGradCount[bIdx] += 1;
        }
      }
    }

    // 4. Estimate block-level displacement vectors (previous -> current AND
    //    rolling 4-frame window -> current for slow laptop movement) and check
    //    stationary background / perimeter anchors.
    final staticBlockThreshold = math.max(0.020, _motionThreshold * 0.36);
    final activeBlockThreshold = math.max(0.024, _motionThreshold * 0.48);

    var texturedRefBlocks = 0;
    var texturedCurrBlocks = 0;
    var anchoredTexturedBlocks = 0;
    var texturedPerimeterBlocks = 0;
    var anchoredPerimeterBlocks = 0;
    var activeMovingBlocks = 0;
    var displacedOrChangedBlocks = 0;
    var texturedRefScoreSum = 0.0;
    var currGradSumAll = 0.0;
    var currGradBlocksCount = 0;
    var refMeanSumAll = 0.0;
    var refMeanBlocksCount = 0;

    final dxList = <double>[];
    final dyList = <double>[];
    final bxList = <int>[];
    final byList = <int>[];
    final quadrantActivity = Int32List(4);

    final winDxList = <double>[];
    final winDyList = <double>[];
    final winBxList = <int>[];
    final winByList = <int>[];
    final winQuadrantActivity = Int32List(4);

    final blockW = gridWidth ~/ _blocksX;
    final blockH = gridHeight ~/ _blocksY;
    final hasWindowSpan = _recentGrids.length >= 3;

    for (var by = 0; by < _blocksY; by++) {
      for (var bx = 0; bx < _blocksX; bx++) {
        final b = by * _blocksX + bx;
        final pxCount = blockPixelCount[b];
        if (pxCount <= 0) {
          continue;
        }
        final refScore = blockRefDiffSum[b] / (pxCount * 255.0);
        final stepScore = blockStepDiffSum[b] / (pxCount * 255.0);
        final winScore = blockWinDiffSum[b] / (pxCount * 255.0);
        final meanGrad = blockGradCount[b] > 0
            ? (blockRefGradSum[b] / blockGradCount[b])
            : 0.0;
        final currGrad = blockGradCount[b] > 0
            ? (blockCurrGradSum[b] / blockGradCount[b])
            : 0.0;
        if (blockGradCount[b] > 0) {
          currGradSumAll += currGrad;
          currGradBlocksCount += 1;
          if (currGrad >= 3.2) {
            texturedCurrBlocks += 1;
          }
        }
        refMeanSumAll += blockRefMean[b];
        refMeanBlocksCount += 1;
        if (refScore >= staticBlockThreshold ||
            (blockCurrMean[b] - blockRefMean[b]).abs() >= 14.0) {
          displacedOrChangedBlocks += 1;
        }
        final isTextured = meanGrad >= 3.2;
        final isPerimeter =
            bx == 0 || bx == (_blocksX - 1) || by == 0 || by == (_blocksY - 1);

        if (stepScore < 0.010) {
          _settledBlockStreak[b] += 1;
        } else {
          _settledBlockStreak[b] = 0;
        }

        if (isTextured) {
          texturedRefBlocks += 1;
          texturedRefScoreSum += refScore;
          if (isPerimeter) {
            texturedPerimeterBlocks += 1;
          }
          if (refScore < staticBlockThreshold && stepScore < 0.016) {
            anchoredTexturedBlocks += 1;
            if (isPerimeter) {
              anchoredPerimeterBlocks += 1;
            }
          }
        }

        final blockStepShift = blockCurrMean[b] - blockPrevMean[b];
        var blockTranslated = false;
        // Require current block to retain spatial detail too so a flat hand/palm
        // wiping across the lens does not produce spurious aperture vectors,
        // while allowing textured features that pan into a previously smooth
        // wall block to contribute rigid optical flow.
        final hasFlowTexture =
            (isTextured || currGrad >= 3.2) && currGrad >= 1.8;
        if (hasFlowTexture &&
            stepScore >= 0.008 &&
            blockW >= 6 &&
            blockH >= 6) {
          final flow =
              _estimateLucasKanadeFlow(
                previous: previous,
                current: currentGrid,
                stepMeanShift: blockStepShift,
                x0: bx * blockW,
                y0: by * blockH,
                w: blockW,
                h: blockH,
              ) ??
              _estimateBlockTranslation(
                previous: previous,
                current: currentGrid,
                stepMeanShift: blockStepShift,
                x0: bx * blockW,
                y0: by * blockH,
                w: blockW,
                h: blockH,
              );
          if (flow != null) {
            blockTranslated = true;
            dxList.add(flow.$1);
            dyList.add(flow.$2);
            bxList.add(bx);
            byList.add(by);
          }
        }

        if (hasWindowSpan &&
            hasFlowTexture &&
            winScore >= 0.010 &&
            blockW >= 6 &&
            blockH >= 6) {
          final winShift = blockCurrMean[b] - blockWinMean[b];
          final winFlow =
              _estimateLucasKanadeFlow(
                previous: windowGrid,
                current: currentGrid,
                stepMeanShift: winShift,
                x0: bx * blockW,
                y0: by * blockH,
                w: blockW,
                h: blockH,
                minMagnitude: 0.36,
              ) ??
              _estimateBlockTranslation(
                previous: windowGrid,
                current: currentGrid,
                stepMeanShift: winShift,
                x0: bx * blockW,
                y0: by * blockH,
                w: blockW,
                h: blockH,
              );
          if (winFlow != null) {
            winDxList.add(winFlow.$1);
            winDyList.add(winFlow.$2);
            winBxList.add(bx);
            winByList.add(by);
            final qx = bx >= 2 ? 1 : 0;
            final qy = by >= 2 ? 1 : 0;
            winQuadrantActivity[qy * 2 + qx] += 1;
          }
        }

        if ((refScore >= activeBlockThreshold && stepScore >= 0.012) ||
            blockTranslated) {
          activeMovingBlocks += 1;
          final qx = bx >= 2 ? 1 : 0;
          final qy = by >= 2 ? 1 : 0;
          quadrantActivity[qy * 2 + qx] += 1;
        }
      }
    }

    var activeQuadrants = 0;
    var winActiveQuadrants = 0;
    for (var q = 0; q < 4; q++) {
      if (quadrantActivity[q] >= 1) {
        activeQuadrants += 1;
      }
      if (winQuadrantActivity[q] >= 1) {
        winActiveQuadrants += 1;
      }
    }

    final stepFlowStats = _evaluateFlowCoherence(
      dxList: dxList,
      dyList: dyList,
      bxList: bxList,
      byList: byList,
    );
    final winFlowStats = _evaluateFlowCoherence(
      dxList: winDxList,
      dyList: winDyList,
      bxList: winBxList,
      byList: winByList,
    );

    final coherentTranslatedBlocks = stepFlowStats.coherentCount;
    final loomingRejected =
        stepFlowStats.isLooming ||
        (coherentTranslatedBlocks < 5 && winFlowStats.isLooming);

    // Check for immediate 180° flow reversal (mechanical desk bump / lid hinge
    // bounce or a hand swiping in and immediately back out).
    var oscillationRejected = false;
    final currFlowMag = math.sqrt(
      (stepFlowStats.meanDx * stepFlowStats.meanDx) +
          (stepFlowStats.meanDy * stepFlowStats.meanDy),
    );
    if (dxList.length >= 3 && currFlowMag >= 0.30) {
      if (_hasPrevMeanFlow) {
        final prevMag = math.sqrt(
          (_prevMeanFlowDx * _prevMeanFlowDx) +
              (_prevMeanFlowDy * _prevMeanFlowDy),
        );
        if (prevMag >= 0.30) {
          final cosTurn =
              ((_prevMeanFlowDx * stepFlowStats.meanDx) +
                  (_prevMeanFlowDy * stepFlowStats.meanDy)) /
              (prevMag * currFlowMag);
          if (cosTurn < -0.25) {
            oscillationRejected = true;
          }
        }
      }
      _prevMeanFlowDx = stepFlowStats.meanDx;
      _prevMeanFlowDy = stepFlowStats.meanDy;
      _hasPrevMeanFlow = true;
    } else if (activeMovingBlocks == 0) {
      _hasPrevMeanFlow = false;
    }

    final rawSceneScore = rawDiffSum / (count * 255.0);
    final fullSceneStructScore = normRefDiffSum / (count * 255.0);
    final meanStepScore = normStepDiffSum / (count * 255.0);
    final meanCurrGrad = currGradBlocksCount > 0
        ? (currGradSumAll / currGradBlocksCount)
        : 0.0;
    final refGlobalMean = refMeanBlocksCount > 0
        ? (refMeanSumAll / refMeanBlocksCount)
        : currMean;

    // Multi-signal webcam obstruction classification:
    //   1. 'dark' — near-zero brightness (shutter, dark cover, black tape).
    //   2. 'bright_glare' — bright washout/flashlight glare with collapsed edges.
    //   3. 'opaque_cover' — flat opaque object/card with collapsed contrast/edges.
    //   4. 'texture_collapse' — close palm/hand/cloth over lens (mid-tone blurry
    //      skin or fabric with shading/vignette: non-black, non-zero deviation,
    //      sudden total loss of anchored landmarks and spatial edge detail).
    String? candidateObstruction;
    if (normalizedLuminance < 0.032) {
      candidateObstruction = 'dark';
    } else if ((normalizedLuminance > 0.92 &&
            normalizedDeviation < 0.065 &&
            texturedCurrBlocks <= 1) ||
        (normalizedLuminance > 0.86 &&
            anchoredTexturedBlocks == 0 &&
            texturedCurrBlocks == 0 &&
            (currMean - refGlobalMean).abs() >= 45.0)) {
      candidateObstruction = 'bright_glare';
    } else if (normalizedDeviation < 0.012 &&
        texturedCurrBlocks == 0 &&
        (texturedRefBlocks == 0 || anchoredTexturedBlocks == 0)) {
      candidateObstruction = 'opaque_cover';
    } else if (_baselineTexturedBlocks >= 2 &&
        anchoredTexturedBlocks == 0 &&
        texturedCurrBlocks <= 1 &&
        (texturedCurrBlocks == 0 || _baselineTexturedBlocks >= 5) &&
        meanCurrGrad < math.min(2.35, _baselineMeanGrad * 0.42) &&
        coherentTranslatedBlocks <= 1 &&
        (rawSceneScore >= 0.045 ||
            fullSceneStructScore >= 0.032 ||
            displacedOrChangedBlocks >= 11)) {
      candidateObstruction = 'texture_collapse';
    }

    var obstructionJustTriggered = false;
    if (candidateObstruction != null) {
      _unobstructedFrameStreak = 0;
      _lastObstructionKind = candidateObstruction;
      if (_wasUnobstructedDuringSession) {
        _consecutiveObstructedFrames += 1;
        if (_consecutiveObstructedFrames >= 6 && !_isInputDegraded) {
          _isInputDegraded = true;
          poorInputJustChanged = true;
        }
        if (_consecutiveObstructedFrames >= obstructionConfirmationFrames &&
            !_isCameraObstructed) {
          _isCameraObstructed = true;
          obstructionJustTriggered = true;
          if (!_isInputDegraded) {
            _isInputDegraded = true;
            poorInputJustChanged = true;
          }
        }
      } else if (!_isInputDegraded) {
        _isInputDegraded = true;
        poorInputJustChanged = true;
      }
    } else {
      _consecutiveObstructedFrames = 0;
      _unobstructedFrameStreak += 1;
      if (!_wasUnobstructedDuringSession && _unobstructedFrameStreak >= 3) {
        _wasUnobstructedDuringSession = true;
        _isObstructedAtCalibration = false;
        for (var i = 0; i < count; i++) {
          reference[i] = currentGrid[i];
        }
        _captureBaselineTextureProfile(reference);
      }
      if (_isCameraObstructed && _unobstructedFrameStreak >= 2) {
        _isCameraObstructed = false;
        _lastObstructionKind = null;
      } else if (!_isCameraObstructed && !_isInputDegraded) {
        _lastObstructionKind = null;
      }
      if (_isInputDegraded &&
          _unobstructedFrameStreak >= 2 &&
          normalizedLuminance >= 0.04 &&
          normalizedDeviation >= 0.012) {
        _isInputDegraded = false;
        poorInputJustChanged = true;
        _lastObstructionKind = null;
      }
    }

    final texturedStructScore = texturedRefBlocks > 0
        ? (texturedRefScoreSum / texturedRefBlocks)
        : fullSceneStructScore;
    final structSceneScore =
        (texturedRefBlocks >= 1 &&
            texturedRefBlocks <= 6 &&
            anchoredTexturedBlocks == 0)
        ? math.max(fullSceneStructScore, texturedStructScore * 0.85)
        : fullSceneStructScore;

    // 5. Abrupt global lighting transient check (e.g. room light switched on/off).
    final meanJump = (currMean - _previousMean255).abs();
    final isLightingTransient =
        meanJump >= 18.0 && coherentTranslatedBlocks <= 2;

    // 6. Separate camera ego-motion from stationary-camera scene motion:
    //    - If >= 22% (min 3) of textured landmarks (such as the upper wall
    //      corners behind a seated or leaning person) stay anchored, the
    //      camera body did not translate or tilt.
    //    - If radial looming dominates without rigid pan/roll coherence, a
    //      person or hand is approaching the lens rather than moving the laptop.
    //    - If inter-frame movement has ceased (static occupancy after someone
    //      sits down in front of the laptop), do not score static difference
    //      from t=0 as active movement.
    final minAnchors = math.max(3, (texturedRefBlocks * 0.22).ceil());
    final hasStrongStaticAnchors =
        (texturedRefBlocks >= 4 && anchoredTexturedBlocks >= minAnchors) ||
        (texturedPerimeterBlocks >= 4 &&
            anchoredPerimeterBlocks >=
                math.max(3, (texturedPerimeterBlocks * 0.34).ceil()));

    final minSparseCoherent = texturedRefBlocks <= 2 ? 1 : 2;
    final sparseSceneCoherentEgoMotion =
        texturedRefBlocks >= 1 &&
        texturedRefBlocks <= 6 &&
        anchoredTexturedBlocks == 0 &&
        texturedStructScore >= activeBlockThreshold &&
        coherentTranslatedBlocks >= minSparseCoherent &&
        stepFlowStats.rigidCoherence >= 0.58 &&
        !loomingRejected;

    final sparseSceneSlowDrift =
        hasWindowSpan &&
        texturedRefBlocks >= 1 &&
        texturedRefBlocks <= 6 &&
        anchoredTexturedBlocks == 0 &&
        texturedStructScore >= activeBlockThreshold &&
        winFlowStats.coherentCount >= minSparseCoherent &&
        winFlowStats.rigidCoherence >= 0.68 &&
        !winFlowStats.isLooming;

    final fullSceneSlowDrift =
        hasWindowSpan &&
        !hasStrongStaticAnchors &&
        !isLightingTransient &&
        !loomingRejected &&
        winFlowStats.coherentCount >= 5 &&
        winActiveQuadrants >= 3 &&
        winFlowStats.rigidCoherence >= 0.70;

    final isScenePresentlyStill =
        coherentTranslatedBlocks == 0 &&
        !fullSceneSlowDrift &&
        !sparseSceneSlowDrift &&
        (activeMovingBlocks <= 2 || meanStepScore < 0.009);

    double egoWeight;
    if (candidateObstruction != null ||
        isLightingTransient ||
        _isInputDegraded) {
      egoWeight = 0.08;
    } else if (hasStrongStaticAnchors) {
      egoWeight = 0.14;
    } else if (loomingRejected) {
      egoWeight = 0.18;
    } else if (isScenePresentlyStill) {
      egoWeight = 0.08;
    } else if (sparseSceneCoherentEgoMotion) {
      egoWeight = 1.20;
    } else if (coherentTranslatedBlocks >= 5 &&
        activeQuadrants >= 3 &&
        stepFlowStats.rigidCoherence >= 0.56) {
      egoWeight = 1.25;
    } else if (activeQuadrants <= 2 && coherentTranslatedBlocks < 5) {
      egoWeight = 0.24;
    } else if (texturedRefBlocks > 0 &&
        anchoredPerimeterBlocks == 0 &&
        anchoredTexturedBlocks == 0 &&
        activeMovingBlocks >= 12 &&
        activeQuadrants == 4 &&
        normalizedDeviation >= 0.028 &&
        dxList.length >= 3 &&
        stepFlowStats.rigidCoherence >= 0.55) {
      // Rapid full-frame carry with partial motion blur but verified rigid alignment.
      egoWeight = 1.08;
    } else if (texturedRefBlocks == 0 &&
        activeMovingBlocks >= 13 &&
        activeQuadrants == 4 &&
        meanStepScore >= 0.025 &&
        normalizedDeviation >= 0.015) {
      egoWeight = 0.95;
    } else {
      egoWeight = 0.32;
    }

    final flowContribution =
        (!hasStrongStaticAnchors &&
            !loomingRejected &&
            coherentTranslatedBlocks >= 5 &&
            activeQuadrants >= 3 &&
            stepFlowStats.rigidCoherence >= 0.56)
        ? (coherentTranslatedBlocks / _totalBlocks) *
              0.11 *
              stepFlowStats.rigidCoherence
        : (sparseSceneCoherentEgoMotion ? 0.045 : 0.0);

    final fastMotionScore = ((structSceneScore * egoWeight) + flowContribution)
        .clamp(0.0, 1.0);

    var slowDriftScore = 0.0;
    if (fullSceneSlowDrift || sparseSceneSlowDrift) {
      final driftFlowBonus =
          (winFlowStats.coherentCount / _totalBlocks) *
          0.11 *
          winFlowStats.rigidCoherence;
      slowDriftScore =
          ((structSceneScore * 1.15 * winFlowStats.rigidCoherence) +
                  driftFlowBonus)
              .clamp(0.0, 1.0);
    }

    var motionScore = math.max(fastMotionScore, slowDriftScore);

    if (hasStrongStaticAnchors || loomingRejected) {
      motionScore = math.min(motionScore, _motionThreshold * 0.62);
    }
    if (oscillationRejected) {
      motionScore = math.min(motionScore, _motionThreshold * 0.72);
    }

    // 7. Update reference, previous frame, and rolling 4-frame drift window.
    //    - Passing foreground objects do not ghost into anchored backgrounds.
    //    - Stationary changes that have settled for >= 4 frames gently adapt
    //      so someone sitting down in front of the laptop becomes the new
    //      clean stationary baseline instead of holding reference diff high.
    if (candidateObstruction != null) {
      // Freeze stationary reference adaptation while an obstruction candidate is
      // covering the lens so a palm, sticky note, or glare never overwrites the
      // calibrated room baseline, and do not accumulate movement triggers.
      _consecutiveAboveThreshold = 0;
      motionScore = math.min(motionScore, _motionThreshold * 0.45);
      for (var i = 0; i < count; i++) {
        previous[i] = currentGrid[i];
      }
    } else {
      final baseAdaptRate = isLightingTransient ? 0.30 : 0.06;
      if (motionScore >= _motionThreshold) {
        _consecutiveAboveThreshold += 1;
        for (var i = 0; i < count; i++) {
          reference[i] = (0.98 * reference[i]) + (0.02 * currentGrid[i]);
          previous[i] = currentGrid[i];
        }
      } else {
        _consecutiveAboveThreshold = 0;
        for (var gy = 0; gy < gridHeight; gy++) {
          final by = math.min(_blocksY - 1, (gy * _blocksY) ~/ gridHeight);
          for (var gx = 0; gx < gridWidth; gx++) {
            final bx = math.min(_blocksX - 1, (gx * _blocksX) ~/ gridWidth);
            final bIdx = by * _blocksX + bx;
            final pxCount = blockPixelCount[bIdx];
            final blockRefScore = pxCount > 0
                ? (blockRefDiffSum[bIdx] / (pxCount * 255.0))
                : 0.0;
            final double alpha;
            if (_settledBlockStreak[bIdx] >= 4 && isScenePresentlyStill) {
              alpha = 0.16;
            } else if (hasStrongStaticAnchors &&
                blockRefScore >= staticBlockThreshold) {
              alpha = 0.01;
            } else {
              alpha = baseAdaptRate;
            }
            final i = gy * gridWidth + gx;
            reference[i] =
                ((1.0 - alpha) * reference[i]) + (alpha * currentGrid[i]);
            previous[i] = currentGrid[i];
          }
        }
      }
    }
    _previousMean255 = currMean;

    _recentGrids.add(Float32List.fromList(currentGrid));
    if (_recentGrids.length > _driftWindowFrames) {
      _recentGrids.removeAt(0);
    }

    final triggered = _consecutiveAboveThreshold >= persistenceFramesRequired;

    return CameraMotionFrameEvaluation(
      isCalibrating: false,
      calibrationJustCompleted: false,
      isPoorInput: _isInputDegraded,
      poorInputJustChanged: poorInputJustChanged,
      isLightingTransient: isLightingTransient,
      motionScore: motionScore,
      rawSceneScore: rawSceneScore,
      threshold: _motionThreshold,
      normalizedLuminance: normalizedLuminance,
      consecutiveAboveThreshold: _consecutiveAboveThreshold,
      triggered: triggered,
      texturedReferenceBlocks: texturedRefBlocks,
      anchoredTexturedBlocks: anchoredTexturedBlocks,
      activeQuadrants: math.max(activeQuadrants, winActiveQuadrants),
      coherentTranslatedBlocks: math.max(
        coherentTranslatedBlocks,
        fullSceneSlowDrift || sparseSceneSlowDrift
            ? winFlowStats.coherentCount
            : 0,
      ),
      slowDriftScore: slowDriftScore,
      rigidCoherence: math.max(
        stepFlowStats.rigidCoherence,
        winFlowStats.rigidCoherence,
      ),
      loomingRejected: loomingRejected,
      oscillationRejected: oscillationRejected,
      cameraObstructed: _isCameraObstructed,
      obstructionJustTriggered: obstructionJustTriggered,
      obstructionKind: _lastObstructionKind,
      isObstructedAtCalibration: _isObstructedAtCalibration,
      consecutiveObstructedFrames: _consecutiveObstructedFrames,
    );
  }

  _FlowCoherenceStats _evaluateFlowCoherence({
    required List<double> dxList,
    required List<double> dyList,
    required List<int> bxList,
    required List<int> byList,
  }) {
    final n = dxList.length;
    if (n == 0) {
      return _FlowCoherenceStats.empty;
    }

    var sumDx = 0.0;
    var sumDy = 0.0;
    var sumMag = 0.0;
    var cx = 0.0;
    var cy = 0.0;
    for (var k = 0; k < n; k++) {
      sumDx += dxList[k];
      sumDy += dyList[k];
      sumMag += math.sqrt((dxList[k] * dxList[k]) + (dyList[k] * dyList[k]));
      cx += bxList[k];
      cy += byList[k];
    }

    final meanDx = sumDx / n;
    final meanDy = sumDy / n;
    final meanMag = sumMag / n;
    cx /= n;
    cy /= n;

    final netMag = math.sqrt((meanDx * meanDx) + (meanDy * meanDy));
    final panCoherence = meanMag > 1e-6
        ? (netMag / meanMag).clamp(0.0, 1.0)
        : 0.0;

    var panAligned = 0;
    var rollPos = 0;
    var rollNeg = 0;
    var tangentialCosSum = 0.0;
    var radialCosSum = 0.0;
    var radialSamples = 0;

    for (var k = 0; k < n; k++) {
      final ux = dxList[k];
      final uy = dyList[k];
      final mag = math.sqrt((ux * ux) + (uy * uy));
      if (mag <= 1e-6) {
        continue;
      }

      if (netMag > 1e-6) {
        final cosPan = ((ux * meanDx) + (uy * meanDy)) / (mag * netMag);
        if (cosPan >= 0.45) {
          panAligned += 1;
        }
      }

      // Roll is evaluated around the camera optical center (1.5, 1.5).
      final ox = bxList[k] - 1.5;
      final oy = byList[k] - 1.5;
      final oRad = math.sqrt((ox * ox) + (oy * oy));
      final cross = (ox * uy) - (oy * ux);
      if (cross > 0.25) {
        rollPos += 1;
      } else if (cross < -0.25) {
        rollNeg += 1;
      }
      if (oRad >= 0.45) {
        final tx = -oy / oRad;
        final ty = ox / oRad;
        tangentialCosSum += ((ux * tx) + (uy * ty)) / mag;
      }

      // Looming (person/hand leaning toward camera) expands outward from the
      // active foreground centroid (cx, cy) or optical center.
      final rx = bxList[k] - cx;
      final ry = byList[k] - cy;
      final rRad = math.sqrt((rx * rx) + (ry * ry));
      if (rRad >= 0.45) {
        radialCosSum += ((ux * (rx / rRad)) + (uy * (ry / rRad))) / mag;
        radialSamples += 1;
      }
    }

    final rollCoherence = (tangentialCosSum.abs() / n).clamp(0.0, 1.0);
    final rigidCoherence = math.max(panCoherence, rollCoherence);
    final radialDivergence = radialSamples >= 3
        ? (radialCosSum / radialSamples).clamp(-1.0, 1.0)
        : 0.0;
    final coherentCount = math.max(panAligned, math.max(rollPos, rollNeg));

    // Radial expansion/contraction without rigid pan or roll consensus indicates
    // an object/person leaning toward or away from a stationary webcam.
    final isLooming =
        n >= 3 && radialDivergence.abs() >= 0.44 && rigidCoherence < 0.64;

    return _FlowCoherenceStats(
      coherentCount: coherentCount,
      panCoherence: panCoherence,
      rollCoherence: rollCoherence,
      rigidCoherence: rigidCoherence,
      radialDivergence: radialDivergence,
      meanDx: meanDx,
      meanDy: meanDy,
      isLooming: isLooming,
    );
  }

  /// Solves the 2x2 Lucas-Kanade optical flow normal equations over block
  /// `[x0..x0+w, y0..y0+h]` with Shi-Tomasi minimum-eigenvalue conditioning.
  (double, double)? _estimateLucasKanadeFlow({
    required Float32List previous,
    required Float32List current,
    required double stepMeanShift,
    required int x0,
    required int y0,
    required int w,
    required int h,
    double minMagnitude = 0.32,
  }) {
    final startX = math.max(1, x0);
    final endX = math.min(gridWidth - 1, x0 + w);
    final startY = math.max(1, y0);
    final endY = math.min(gridHeight - 1, y0 + h);
    if (endX <= startX + 2 || endY <= startY + 2) {
      return null;
    }

    var sxx = 0.0;
    var syy = 0.0;
    var sxy = 0.0;
    var bx = 0.0;
    var by = 0.0;
    var count = 0;

    for (var y = startY; y < endY; y++) {
      final row = y * gridWidth;
      final rowUp = (y - 1) * gridWidth;
      final rowDown = (y + 1) * gridWidth;
      for (var x = startX; x < endX; x++) {
        final ix =
            0.25 *
            ((previous[row + x + 1] - previous[row + x - 1]) +
                (current[row + x + 1] - current[row + x - 1]));
        final iy =
            0.25 *
            ((previous[rowDown + x] - previous[rowUp + x]) +
                (current[rowDown + x] - current[rowUp + x]));
        final it = (current[row + x] - previous[row + x]) - stepMeanShift;

        sxx += ix * ix;
        syy += iy * iy;
        sxy += ix * iy;
        bx -= ix * it;
        by -= iy * it;
        count += 1;
      }
    }

    if (count == 0) {
      return null;
    }

    final trace = sxx + syy;
    final det = (sxx * syy) - (sxy * sxy);
    final disc = math.max(0.0, (trace * trace) - (4.0 * det));
    final minEigen = 0.5 * (trace - math.sqrt(disc));

    // Reject aperture-ambiguous or flat blocks.
    if (det <= 1e-3 || minEigen < count * 6.0) {
      return null;
    }

    final u = ((syy * bx) - (sxy * by)) / det;
    final v = ((-sxy * bx) + (sxx * by)) / det;
    final mag = math.sqrt((u * u) + (v * v));
    if (mag < minMagnitude || mag > 3.8) {
      return null;
    }
    return (u, v);
  }

  (double, double)? _estimateBlockTranslation({
    required Float32List previous,
    required Float32List current,
    required double stepMeanShift,
    required int x0,
    required int y0,
    required int w,
    required int h,
  }) {
    const maxShift = 3;
    final startX = math.max(maxShift, x0 + 1);
    final endX = math.min(gridWidth - maxShift, x0 + w - 1);
    final startY = math.max(maxShift, y0 + 1);
    final endY = math.min(gridHeight - maxShift, y0 + h - 1);
    if (endX <= startX + 2 || endY <= startY + 2) {
      return null;
    }

    double sadForShift(int dx, int dy) {
      var sad = 0.0;
      for (var y = startY; y < endY; y++) {
        final prevRow = y * gridWidth;
        final currRow = (y + dy) * gridWidth;
        for (var x = startX; x < endX; x++) {
          final prevVal = previous[prevRow + x];
          final currVal = current[currRow + x + dx] - stepMeanShift;
          sad += (currVal - prevVal).abs();
        }
      }
      return sad;
    }

    final sadZero = sadForShift(0, 0);
    final samplePixels = (endX - startX) * (endY - startY);
    if (sadZero / samplePixels < 2.2) {
      return null;
    }

    var bestSad = sadZero;
    var bestDx = 0;
    var bestDy = 0;

    for (var dy = -maxShift; dy <= maxShift; dy++) {
      for (var dx = -maxShift; dx <= maxShift; dx++) {
        if (dx == 0 && dy == 0) {
          continue;
        }
        final sad = sadForShift(dx, dy);
        if (sad < bestSad) {
          bestSad = sad;
          bestDx = dx;
          bestDy = dy;
        }
      }
    }

    if ((bestDx != 0 || bestDy != 0) && bestSad < sadZero * 0.84) {
      return (bestDx.toDouble(), bestDy.toDouble());
    }
    return null;
  }
}
