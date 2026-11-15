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
}

/// Stateful camera ego-motion estimator using Lucas-Kanade 2x2 optical flow,
/// coarse block displacement matching, static background landmark anchoring,
/// and affine illumination normalization.
///
/// Distinguishes physical laptop movement (pickup, tilt, pan, rotation) from
/// people walking in front of a stationary laptop and brief lighting changes.
class CameraMotionAnalyzer {
  CameraMotionAnalyzer({
    this.gridWidth = 64,
    this.gridHeight = 48,
    this.calibrationDuration = const Duration(milliseconds: 1500),
    this.persistenceFramesRequired = 3,
    double motionThreshold = 0.095,
  }) : _motionThreshold = motionThreshold.clamp(0.02, 0.50);

  static const int _blocksX = 4;
  static const int _blocksY = 4;
  static const int _totalBlocks = _blocksX * _blocksY;

  final int gridWidth;
  final int gridHeight;
  final Duration calibrationDuration;
  final int persistenceFramesRequired;

  double _motionThreshold;
  Float32List? _referenceGrid;
  Float32List? _previousGrid;
  double _previousMean255 = 0.0;
  DateTime? _calibrationStart;
  bool _isCalibrationDone = false;
  bool _isInputDegraded = false;
  int _processedFrames = 0;
  int _consecutiveAboveThreshold = 0;
  int _consecutivePoorInputFrames = 0;

  double get motionThreshold => _motionThreshold;
  bool get isCalibrationDone => _isCalibrationDone;
  bool get isInputDegraded => _isInputDegraded;
  int get consecutiveAboveThreshold => _consecutiveAboveThreshold;

  void updateThreshold(double threshold) {
    _motionThreshold = threshold.clamp(0.02, 0.50);
    _consecutiveAboveThreshold = 0;
  }

  void reset() {
    _referenceGrid = null;
    _previousGrid = null;
    _previousMean255 = 0.0;
    _calibrationStart = null;
    _isCalibrationDone = false;
    _isInputDegraded = false;
    _processedFrames = 0;
    _consecutiveAboveThreshold = 0;
    _consecutivePoorInputFrames = 0;
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
          texturedReferenceBlocks: 0,
          anchoredTexturedBlocks: 0,
          activeQuadrants: 0,
          coherentTranslatedBlocks: 0,
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

    // 3. Per-block zero-mean & affine illumination normalization so foreground
    //    objects (dark/bright clothing) never shift the baseline of unoccluded
    //    stationary background blocks, while room lighting steps cancel cleanly.
    final blockCurrSum = Float64List(_totalBlocks);
    final blockRefSum = Float64List(_totalBlocks);
    final blockPrevSum = Float64List(_totalBlocks);
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
        blockPixelCount[bIdx] += 1;
        rawDiffSum += (currentGrid[i] - reference[i]).abs();
      }
    }

    final blockCurrMean = Float64List(_totalBlocks);
    final blockRefMean = Float64List(_totalBlocks);
    final blockPrevMean = Float64List(_totalBlocks);
    for (var b = 0; b < _totalBlocks; b++) {
      final n = blockPixelCount[b];
      if (n > 0) {
        blockCurrMean[b] = blockCurrSum[b] / n;
        blockRefMean[b] = blockRefSum[b] / n;
        blockPrevMean[b] = blockPrevSum[b] / n;
      }
    }

    final blockCurrDevSum = Float64List(_totalBlocks);
    final blockRefDevSum = Float64List(_totalBlocks);
    for (var gy = 0; gy < gridHeight; gy++) {
      final by = math.min(_blocksY - 1, (gy * _blocksY) ~/ gridHeight);
      for (var gx = 0; gx < gridWidth; gx++) {
        final bx = math.min(_blocksX - 1, (gx * _blocksX) ~/ gridWidth);
        final bIdx = by * _blocksX + bx;
        final i = gy * gridWidth + gx;
        blockCurrDevSum[bIdx] += (currentGrid[i] - blockCurrMean[bIdx]).abs();
        blockRefDevSum[bIdx] += (reference[i] - blockRefMean[bIdx]).abs();
      }
    }

    final blockGainToRef = Float64List(_totalBlocks);
    for (var b = 0; b < _totalBlocks; b++) {
      final n = blockPixelCount[b];
      if (n <= 0) {
        blockGainToRef[b] = 1.0;
        continue;
      }
      final cMad = blockCurrDevSum[b] / n;
      final rMad = blockRefDevSum[b] / n;
      blockGainToRef[b] = (cMad > 3.0 && rMad > 3.0)
          ? (rMad / cMad).clamp(0.72, 1.38)
          : 1.0;
    }

    final blockRefDiffSum = Float64List(_totalBlocks);
    final blockStepDiffSum = Float64List(_totalBlocks);
    final blockRefGradSum = Float64List(_totalBlocks);
    final blockGradCount = Int32List(_totalBlocks);

    var normRefDiffSum = 0.0;

    for (var gy = 0; gy < gridHeight; gy++) {
      final by = math.min(_blocksY - 1, (gy * _blocksY) ~/ gridHeight);
      for (var gx = 0; gx < gridWidth; gx++) {
        final bx = math.min(_blocksX - 1, (gx * _blocksX) ~/ gridWidth);
        final bIdx = by * _blocksX + bx;
        final i = gy * gridWidth + gx;

        final currVal = currentGrid[i];
        final refVal = reference[i];
        final prevVal = previous[i];

        // Block-local zero-mean + contrast-normalized structural residual vs reference.
        final normCurrCentered =
            (currVal - blockCurrMean[bIdx]) * blockGainToRef[bIdx];
        final refCentered = refVal - blockRefMean[bIdx];
        final refDelta = (normCurrCentered - refCentered).abs();

        // Block-local zero-mean inter-frame residual vs previous frame.
        final blockStepShift = blockCurrMean[bIdx] - blockPrevMean[bIdx];
        final stepDelta = ((currVal - prevVal) - blockStepShift).abs();

        normRefDiffSum += refDelta;
        blockRefDiffSum[bIdx] += refDelta;
        blockStepDiffSum[bIdx] += stepDelta;

        if (gx + 1 < gridWidth && gy + 1 < gridHeight) {
          final gxDiff = (refVal - reference[i + 1]).abs();
          final gyDiff = (refVal - reference[i + gridWidth]).abs();
          blockRefGradSum[bIdx] += 0.5 * (gxDiff + gyDiff);
          blockGradCount[bIdx] += 1;
        }
      }
    }

    // 4. Estimate block-level displacement vectors (previous -> current) and
    //    evaluate static background landmarks vs. multi-quadrant ego-motion.
    final staticBlockThreshold = math.max(0.020, _motionThreshold * 0.36);
    final activeBlockThreshold = math.max(0.024, _motionThreshold * 0.48);

    var texturedRefBlocks = 0;
    var anchoredTexturedBlocks = 0;
    var changedBlocks = 0;
    var translatedBlocks = 0;
    var texturedRefScoreSum = 0.0;

    final dxList = <double>[];
    final dyList = <double>[];
    final bxList = <int>[];
    final byList = <int>[];
    final quadrantActivity = Int32List(4);

    final blockW = gridWidth ~/ _blocksX;
    final blockH = gridHeight ~/ _blocksY;

    for (var by = 0; by < _blocksY; by++) {
      for (var bx = 0; bx < _blocksX; bx++) {
        final b = by * _blocksX + bx;
        final pxCount = blockPixelCount[b];
        if (pxCount <= 0) {
          continue;
        }
        final refScore = blockRefDiffSum[b] / (pxCount * 255.0);
        final stepScore = blockStepDiffSum[b] / (pxCount * 255.0);
        final meanGrad = blockGradCount[b] > 0
            ? (blockRefGradSum[b] / blockGradCount[b])
            : 0.0;
        final isTextured = meanGrad >= 3.2;

        if (isTextured) {
          texturedRefBlocks += 1;
          texturedRefScoreSum += refScore;
          if (refScore < staticBlockThreshold && stepScore < 0.018) {
            anchoredTexturedBlocks += 1;
          }
        }

        final blockStepShift = blockCurrMean[b] - blockPrevMean[b];
        var blockTranslated = false;
        if (isTextured && stepScore >= 0.008 && blockW >= 6 && blockH >= 6) {
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
            translatedBlocks += 1;
            dxList.add(flow.$1);
            dyList.add(flow.$2);
            bxList.add(bx);
            byList.add(by);
          }
        }

        if ((refScore >= activeBlockThreshold && stepScore >= 0.010) ||
            blockTranslated) {
          changedBlocks += 1;
          final qx = bx >= 2 ? 1 : 0;
          final qy = by >= 2 ? 1 : 0;
          quadrantActivity[qy * 2 + qx] += 1;
        }
      }
    }

    var activeQuadrants = 0;
    for (var q = 0; q < 4; q++) {
      if (quadrantActivity[q] >= 1) {
        activeQuadrants += 1;
      }
    }

    // Compute directional or rotational coherence among translated blocks.
    var coherentTranslatedBlocks = 0;
    if (translatedBlocks > 0) {
      var sumDx = 0.0;
      var sumDy = 0.0;
      var rollPos = 0;
      var rollNeg = 0;
      for (var k = 0; k < translatedBlocks; k++) {
        sumDx += dxList[k];
        sumDy += dyList[k];
        final rx = bxList[k] - 1.5;
        final ry = byList[k] - 1.5;
        final cross = (rx * dyList[k]) - (ry * dxList[k]);
        if (cross > 0.25) {
          rollPos += 1;
        } else if (cross < -0.25) {
          rollNeg += 1;
        }
      }
      var panAligned = 0;
      for (var k = 0; k < translatedBlocks; k++) {
        if ((dxList[k] * sumDx) + (dyList[k] * sumDy) > 0.0) {
          panAligned += 1;
        }
      }
      coherentTranslatedBlocks = math.max(
        panAligned,
        math.max(rollPos, rollNeg),
      );
    }

    final rawSceneScore = rawDiffSum / (count * 255.0);
    final fullSceneStructScore = normRefDiffSum / (count * 255.0);
    final texturedStructScore = texturedRefBlocks > 0
        ? (texturedRefScoreSum / texturedRefBlocks)
        : fullSceneStructScore;
    // In minimalist rooms where most blocks are featureless smooth walls, avoid
    // diluting real displacement of the available textured landmarks.
    final structSceneScore =
        (texturedRefBlocks >= 2 &&
            texturedRefBlocks <= 6 &&
            anchoredTexturedBlocks == 0)
        ? math.max(fullSceneStructScore, texturedStructScore * 0.80)
        : fullSceneStructScore;

    // 5. Abrupt global lighting transient check (e.g. room light switched on/off).
    final meanJump = (currMean - _previousMean255).abs();
    final isLightingTransient =
        meanJump >= 20.0 && coherentTranslatedBlocks <= 2;

    // 6. Compute ego-motion spatial weight to separate stationary-camera
    //    foreground passersby from real laptop movement.
    //    By rigid-body camera kinematics, a moving/rotating camera displaces
    //    nearly all textured landmarks (at most 1-2 blocks near an optical axis
    //    can stay quiet). If >= 28% (and >= 3) of textured reference blocks
    //    remain completely stationary, the camera itself is stationary and any
    //    coherent flow belongs to a foreground person/object passing by.
    double egoWeight;
    final hasStrongStaticAnchors =
        texturedRefBlocks >= 4 &&
        anchoredTexturedBlocks >=
            math.max(3, (texturedRefBlocks * 0.28).ceil());
    final sparseSceneCoherentEgoMotion =
        texturedRefBlocks >= 2 &&
        texturedRefBlocks <= 6 &&
        anchoredTexturedBlocks == 0 &&
        coherentTranslatedBlocks >= math.min(3, texturedRefBlocks);

    if (isLightingTransient) {
      egoWeight = 0.12;
    } else if (hasStrongStaticAnchors) {
      // Stationary background landmarks remain unmoved -> foreground object/person passing.
      egoWeight = 0.16;
    } else if (sparseSceneCoherentEgoMotion) {
      // Minimalist wall scene where 100% of textured features moved coherently.
      egoWeight = 1.20;
    } else if (activeQuadrants <= 2 && coherentTranslatedBlocks < 5) {
      // Motion confined to one side/half of the image without global flow.
      egoWeight = 0.28;
    } else if (coherentTranslatedBlocks >= 5 && activeQuadrants >= 3) {
      // Verified coherent translation/rotation across >= 3 quadrants!
      egoWeight = 1.25;
    } else if (texturedRefBlocks > 0 &&
        anchoredTexturedBlocks <= (texturedRefBlocks * 0.20).floor() &&
        changedBlocks >= 10 &&
        activeQuadrants >= 3) {
      // >= 80% of textured landmarks displaced across >= 3 quadrants (e.g. rapid pickup/blur).
      egoWeight = 1.10;
    } else if (texturedRefBlocks == 0 &&
        changedBlocks >= 12 &&
        activeQuadrants == 4) {
      // Low-texture scene experiencing full-frame movement.
      egoWeight = 1.0;
    } else {
      egoWeight = 0.45;
    }

    // Boost score slightly when verified coherent displacement is present even
    // on subtle camera tilts/rotations where pixel intensity delta is modest.
    final flowContribution =
        (!hasStrongStaticAnchors &&
            coherentTranslatedBlocks >= 5 &&
            activeQuadrants >= 3)
        ? (coherentTranslatedBlocks / _totalBlocks) * 0.11
        : (sparseSceneCoherentEgoMotion ? 0.045 : 0.0);
    var motionScore = ((structSceneScore * egoWeight) + flowContribution).clamp(
      0.0,
      1.0,
    );

    // Ensure foreground motion in front of a stationary anchored background stays below threshold.
    if (hasStrongStaticAnchors) {
      motionScore = math.min(motionScore, _motionThreshold * 0.65);
    }

    // 7. Update reference and previous frame state while preventing foreground
    //    occluders from "ghosting" into the stationary background reference.
    final baseAdaptRate = isLightingTransient ? 0.30 : 0.08;
    if (motionScore >= _motionThreshold) {
      _consecutiveAboveThreshold += 1;
      for (var i = 0; i < count; i++) {
        reference[i] = (0.97 * reference[i]) + (0.03 * currentGrid[i]);
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
          // If the camera is anchored, adapt occluded foreground blocks very
          // slowly (1%) so a passing person never corrupts the background model.
          final alpha =
              (hasStrongStaticAnchors && blockRefScore >= staticBlockThreshold)
              ? 0.01
              : baseAdaptRate;
          final i = gy * gridWidth + gx;
          reference[i] =
              ((1.0 - alpha) * reference[i]) + (alpha * currentGrid[i]);
          previous[i] = currentGrid[i];
        }
      }
    }
    _previousMean255 = currMean;

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
      activeQuadrants: activeQuadrants,
      coherentTranslatedBlocks: coherentTranslatedBlocks,
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
    if (mag < 0.32 || mag > 3.8) {
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
