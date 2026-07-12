import XCTest

final class PiPMotionRegionAnalyzerTests: XCTestCase {
  private let analyzer = PiPMotionRegionAnalyzer()
  private let screenWidth = 160
  private let screenHeight = 240
  private let expectedPiP = PiPMotionRegion(x: 64, y: 156, width: 80, height: 45)

  func testMovingVideoInsideFixedSixteenByNinePiPRegionPasses() throws {
    let frames = syntheticFrames { _, _, _, frameIndex in
      .animated(region: self.expectedPiP, frameIndex: frameIndex)
    }

    let analysis = analyzer.analyze(frames)

    XCTAssertTrue(analysis.passed, diagnostics(for: analysis))
    let detected = try XCTUnwrap(analysis.region)
    XCTAssertGreaterThanOrEqual(
      Double(detected.intersectionArea(with: expectedPiP)) / Double(expectedPiP.area),
      0.85,
      diagnostics(for: analysis)
    )
    XCTAssertGreaterThanOrEqual(analysis.sustainedMotionPairCount, analysis.requiredPairCount)
    XCTAssertGreaterThanOrEqual(analysis.nonBlackFrameCount, frames.count - 1)
  }

  func testWholeScreenAnimationFails() {
    let fullScreen = PiPMotionRegion(
      x: 0,
      y: 0,
      width: screenWidth,
      height: screenHeight
    )
    let frames = syntheticFrames { _, _, _, frameIndex in
      .animated(region: fullScreen, frameIndex: frameIndex)
    }

    let analysis = analyzer.analyze(frames)

    XCTAssertFalse(analysis.passed, diagnostics(for: analysis))
    XCTAssertEqual(analysis.failure, .noStablePiPSizedComponent)
    XCTAssertGreaterThan(analysis.largestPersistentComponentAreaRatio, 0.90)
  }

  func testSmallWidgetAnimationFails() {
    let widget = PiPMotionRegion(x: 104, y: 18, width: 36, height: 36)
    let frames = syntheticFrames { _, _, _, frameIndex in
      .animated(region: widget, frameIndex: frameIndex)
    }

    let analysis = analyzer.analyze(frames)

    XCTAssertFalse(analysis.passed, diagnostics(for: analysis))
    XCTAssertEqual(analysis.failure, .noStablePiPSizedComponent)
    XCTAssertGreaterThan(analysis.largestPersistentComponentAreaRatio, 0.012)
  }

  func testMediumHomeScreenWidgetAnimationFails() {
    let widget = PiPMotionRegion(x: 28, y: 22, width: 104, height: 48)
    let frames = syntheticFrames { _, _, _, frameIndex in
      .animated(region: widget, frameIndex: frameIndex)
    }

    let analysis = analyzer.analyze(frames)

    XCTAssertFalse(analysis.passed, diagnostics(for: analysis))
    XCTAssertEqual(analysis.failure, .noStablePiPSizedComponent)
    XCTAssertGreaterThan(analysis.largestPersistentComponentAreaRatio, 0.10)
  }

  func testSpinnerSizedAnimationFails() {
    let spinner = PiPMotionRegion(x: 132, y: 26, width: 12, height: 12)
    let frames = syntheticFrames { _, _, _, frameIndex in
      .animated(region: spinner, frameIndex: frameIndex)
    }

    let analysis = analyzer.analyze(frames)

    XCTAssertFalse(analysis.passed, diagnostics(for: analysis))
    XCTAssertEqual(analysis.failure, .noStablePiPSizedComponent)
    XCTAssertLessThan(analysis.largestPersistentComponentAreaRatio, 0.012)
  }

  func testRandomScatteredChangesFail() {
    let frames = (0..<6).map(scatteredFrame)

    let analysis = analyzer.analyze(frames)

    XCTAssertFalse(analysis.passed, diagnostics(for: analysis))
    XCTAssertEqual(analysis.failure, .noStablePiPSizedComponent)
  }

  func testStaticNonBlackPiPRegionFails() {
    let frames = syntheticFrames { x, y, _, _ in
      self.expectedPiP.contains(x: x, y: y)
        ? .pixel(PiPMotionPixel(red: 80, green: 170, blue: 220))
        : .background
    }

    let analysis = analyzer.analyze(frames)

    XCTAssertFalse(analysis.passed, diagnostics(for: analysis))
    XCTAssertEqual(analysis.failure, .noStablePiPSizedComponent)
  }

  func testBlackMotionlessFramesFail() {
    let frames = syntheticFrames { _, _, _, _ in .background }

    let analysis = analyzer.analyze(frames)

    XCTAssertFalse(analysis.passed, diagnostics(for: analysis))
    XCTAssertEqual(analysis.failure, .noStablePiPSizedComponent)
  }

  func testDarkAnimatedPiPRegionFailsNonBlackGate() {
    let frames = syntheticFrames { x, y, _, frameIndex in
      guard self.expectedPiP.contains(x: x, y: y) else { return .background }
      let value: UInt8 = frameIndex.isMultiple(of: 2) ? 0 : 35
      return .pixel(PiPMotionPixel(red: value, green: value, blue: value))
    }

    let analysis = analyzer.analyze(frames)

    XCTAssertFalse(analysis.passed, diagnostics(for: analysis))
    XCTAssertEqual(analysis.failure, .insufficientNonBlackContent)
    XCTAssertGreaterThanOrEqual(
      analysis.sustainedMotionPairCount,
      analysis.requiredPairCount
    )
    XCTAssertEqual(analysis.nonBlackFrameCount, 0)
  }

  func testPiPPositionDriftFails() {
    let frames = syntheticFrames { _, _, _, frameIndex in
      let region = PiPMotionRegion(
        x: 44 + frameIndex * 4,
        y: self.expectedPiP.y,
        width: self.expectedPiP.width,
        height: self.expectedPiP.height
      )
      return .animated(region: region, frameIndex: frameIndex)
    }

    let analysis = analyzer.analyze(frames)

    XCTAssertFalse(analysis.passed, diagnostics(for: analysis))
    XCTAssertEqual(analysis.failure, .unstableRegion, diagnostics(for: analysis))
    XCTAssertGreaterThan(
      analysis.horizontalCenterDriftRatio,
      PiPMotionRegionAnalyzer.Configuration.physicalPiP.maximumCenterDriftRatio
    )
  }

  func testRoundedCornersAndStaticControlsStillPass() throws {
    let frames = syntheticFrames { x, y, _, frameIndex in
      guard self.expectedPiP.contains(x: x, y: y) else { return .background }
      guard self.isInsideRoundedPiP(x: x, y: y) else { return .background }
      if self.isStaticControl(x: x, y: y) {
        return .pixel(PiPMotionPixel(red: 92, green: 92, blue: 92))
      }
      return .animated(region: self.expectedPiP, frameIndex: frameIndex)
    }

    let analysis = analyzer.analyze(frames)

    XCTAssertTrue(analysis.passed, diagnostics(for: analysis))
    let detected = try XCTUnwrap(analysis.region)
    XCTAssertGreaterThanOrEqual(
      Double(detected.intersectionArea(with: expectedPiP)) / Double(expectedPiP.area),
      0.80,
      diagnostics(for: analysis)
    )
    XCTAssertGreaterThan(analysis.persistentFillRatio, 0.65)
  }

  func testOneWholeScreenTransitionDoesNotDisplaceStablePiP() {
    let changedBackground = PiPMotionPixel(red: 110, green: 110, blue: 110)
    let frames = syntheticFrames { x, y, _, frameIndex in
      if self.expectedPiP.contains(x: x, y: y) {
        return .animated(region: self.expectedPiP, frameIndex: frameIndex)
      }
      return frameIndex < 2 ? .background : .pixel(changedBackground)
    }

    let analysis = analyzer.analyze(frames)

    XCTAssertTrue(analysis.passed, diagnostics(for: analysis))
    XCTAssertEqual(analysis.matchingPairCount, analysis.requiredPairCount)
    XCTAssertGreaterThanOrEqual(
      analysis.sustainedMotionPairCount,
      analysis.requiredPairCount
    )
  }
}

extension PiPMotionRegionAnalyzerTests {
  fileprivate enum SyntheticPixel {
    case background
    case pixel(PiPMotionPixel)
    case animated(region: PiPMotionRegion, frameIndex: Int)
  }

  private func syntheticFrames(
    count: Int = 6,
    pixel: (Int, Int, Int, Int) -> SyntheticPixel
  ) -> [PiPMotionFrame] {
    (0..<count).map { frameIndex in
      var pixels: [PiPMotionPixel] = []
      pixels.reserveCapacity(screenWidth * screenHeight)
      for y in 0..<screenHeight {
        for x in 0..<screenWidth {
          switch pixel(x, y, y * screenWidth + x, frameIndex) {
          case .background:
            pixels.append(.black)
          case .pixel(let value):
            pixels.append(value)
          case .animated(let region, let animationFrame):
            pixels.append(
              region.contains(x: x, y: y)
                ? animatedPixel(x: x, y: y, frameIndex: animationFrame)
                : .black
            )
          }
        }
      }
      return PiPMotionFrame(
        width: screenWidth,
        height: screenHeight,
        pixels: pixels
      )
    }
  }

  private func scatteredFrame(frameIndex: Int) -> PiPMotionFrame {
    var pixels = [PiPMotionPixel](
      repeating: .black,
      count: screenWidth * screenHeight
    )
    var state = UInt64(frameIndex + 1) &* 0x9E37_79B9_7F4A_7C15
    for sample in 0..<280 {
      state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
      let index = Int(state % UInt64(pixels.count))
      pixels[index] = animatedPixel(
        x: index % screenWidth,
        y: index / screenWidth,
        frameIndex: frameIndex + sample
      )
    }
    return PiPMotionFrame(width: screenWidth, height: screenHeight, pixels: pixels)
  }

  private func animatedPixel(x: Int, y: Int, frameIndex: Int) -> PiPMotionPixel {
    let palette = [
      PiPMotionPixel(red: 225, green: 65, blue: 55),
      PiPMotionPixel(red: 50, green: 215, blue: 90),
      PiPMotionPixel(red: 55, green: 80, blue: 230),
      PiPMotionPixel(red: 235, green: 205, blue: 50),
      PiPMotionPixel(red: 190, green: 50, blue: 215),
      PiPMotionPixel(red: 50, green: 215, blue: 215)
    ]
    return palette[(x / 3 + y / 3 + frameIndex) % palette.count]
  }

  private func isInsideRoundedPiP(x: Int, y: Int) -> Bool {
    let localX = x - expectedPiP.x
    let localY = y - expectedPiP.y
    let radius = 8

    let cornerCenters = [
      (radius, radius),
      (expectedPiP.width - radius - 1, radius),
      (radius, expectedPiP.height - radius - 1),
      (expectedPiP.width - radius - 1, expectedPiP.height - radius - 1)
    ]
    for (centerX, centerY) in cornerCenters {
      let nearHorizontalEdge = centerX < expectedPiP.width / 2
        ? localX < radius
        : localX >= expectedPiP.width - radius
      let nearVerticalEdge = centerY < expectedPiP.height / 2
        ? localY < radius
        : localY >= expectedPiP.height - radius
      if nearHorizontalEdge, nearVerticalEdge {
        let deltaX = localX - centerX
        let deltaY = localY - centerY
        return deltaX * deltaX + deltaY * deltaY <= radius * radius
      }
    }
    return true
  }

  private func isStaticControl(x: Int, y: Int) -> Bool {
    let centerX = expectedPiP.x + expectedPiP.width / 2
    let centerY = expectedPiP.y + expectedPiP.height / 2
    let deltaX = x - centerX
    let deltaY = y - centerY
    let centerControl = deltaX * deltaX + deltaY * deltaY <= 7 * 7
    let bottomBar = y >= expectedPiP.maxY - 7
      && y < expectedPiP.maxY - 4
      && x >= centerX - 16
      && x <= centerX + 16
    return centerControl || bottomBar
  }

  private func diagnostics(for analysis: PiPMotionRegionAnalysis) -> String {
    "failure=\(analysis.failure?.rawValue ?? "none"), "
      + "region=\(String(describing: analysis.region)), "
      + "pairMotion=\(analysis.pairMotionRatios), "
      + "nonBlack=\(analysis.frameNonBlackRatios), "
      + "matching=\(analysis.matchingPairCount)/\(analysis.requiredPairCount), "
      + "drift=(\(analysis.horizontalCenterDriftRatio), "
      + "\(analysis.verticalCenterDriftRatio))"
  }
}

extension PiPMotionRegion {
  fileprivate func contains(x: Int, y: Int) -> Bool {
    x >= self.x && x < maxX && y >= self.y && y < maxY
  }
}
