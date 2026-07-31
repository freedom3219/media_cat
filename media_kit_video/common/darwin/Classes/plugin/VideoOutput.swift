#if canImport(Flutter)
  import Flutter
#elseif canImport(FlutterMacOS)
  import FlutterMacOS
#endif

// This class creates and manipulates the different types of FlutterTexture,
// handles resizing, rendering calls, and notify Flutter when a new frame is
// available to render.
//
// To improve the user experience, a worker is used to execute heavy tasks on a
// dedicated thread.
public class VideoOutput: NSObject {
  // Will be called on the main thread
  public typealias TextureUpdateCallback = (Int64, CGSize) -> Void

  #if os(macOS)
    private struct RenderResult {
      let resizedTo: CGSize?
    }
  #endif

  private static let isSimulator: Bool = {
    let isSim: Bool
    #if targetEnvironment(simulator)
      isSim = true
    #else
      isSim = false
    #endif
    return isSim
  }()

  private let handle: OpaquePointer
  private let enableHardwareAcceleration: Bool
  private let registry: FlutterTextureRegistry
  private let textureUpdateCallback: TextureUpdateCallback
  private let worker: Worker = .init()
  private var width: Int64?
  private var height: Int64?
  private var texture: ResizableTextureProtocol!
  private var textureId: Int64 = -1
  private var currentSize: CGSize = CGSize.zero
  private var disposed: Bool = false

  #if os(macOS)
    // Coalesce decoder callbacks while AppKit and Flutter share the main thread.
    private var hasRenderedFrame: Bool = false
    private let renderRequestLock = NSLock()
    private var renderJobScheduled: Bool = false
    private var renderJobRunning: Bool = false
    private var frameNotificationPending: Bool = false
    private var renderDirty: Bool = false
  #endif

  init(
    handle: Int64,
    configuration: VideoOutputConfiguration,
    registry: FlutterTextureRegistry,
    textureUpdateCallback: @escaping TextureUpdateCallback
  ) {
    let handle = OpaquePointer(bitPattern: Int(handle))
    assert(handle != nil, "handle casting")

    self.handle = handle!
    width = configuration.width
    height = configuration.height
    enableHardwareAcceleration = configuration.enableHardwareAcceleration
    self.registry = registry
    self.textureUpdateCallback = textureUpdateCallback

    super.init()

    worker.enqueue {
      self._init()
    }
  }

  deinit {
    worker.cancel()

    disposed = true
    disposeTextureId()
  }

  public func setSize(width: Int64?, height: Int64?) {
    worker.enqueue {
      self.width = width
      self.height = height

      #if os(macOS)
      // mpv does not emit a render callback while paused, so redraw the
      // already published frame when its output target changes.
      if self.hasRenderedFrame && self.currentSize != self.videoSize {
        self.requestRender()
      }
      #endif
    }
  }

  private func _init() {
    let enableHardwareAcceleration =
      VideoOutput.isSimulator ? false : enableHardwareAcceleration

    NSLog(
      "VideoOutput: enableHardwareAcceleration: \(enableHardwareAcceleration)"
    )

    if VideoOutput.isSimulator {
      NSLog(
        "VideoOutput: warning: hardware rendering is disabled in the iOS simulator, due to an incompatibility with OpenGL ES"
      )
    }

    if enableHardwareAcceleration {
      texture = SafeResizableTexture(
        TextureHW(
          handle: handle,
          // Use `weak self` to prevent memory leaks
          updateCallback: { [weak self]() in
            guard let that = self else {
              return
            }
            that.updateCallback()
          }
        )
      )
    } else {
      texture = SafeResizableTexture(
        TextureSW(
          handle: handle,
          // Use `weak self` to prevent memory leaks
          updateCallback: { [weak self]() in
            guard let that = self else {
              return
            }
            that.updateCallback()
          }
        )
      )
    }

    DispatchQueue.main.sync { [weak self]() in
      guard let that = self else {
        return
      }
      that.registerTextureId()
    }
  }

  // Must be run on the main thread
  private func registerTextureId() {
    // Textures must be registered on the platform thread.
    textureId = registry.register(texture)
    // textureUpdateCallback must run on the main thread
    textureUpdateCallback(textureId, CGSize(width: 0, height: 0))
  }

  private func disposeTextureId() {
    let registry_ = self.registry
    let textureId_ = self.textureId
    textureId = -1
    DispatchQueue.main.async {
      // Textures must be unregistered on the platform thread
      registry_.unregisterTexture(textureId_)
    }
  }

  public func updateCallback() {
    #if os(macOS)
      requestRender()
    #else
      worker.enqueue {
        self.updateSynchronously()
      }
    #endif
  }

  #if os(macOS)
    private func requestRender() {
      renderRequestLock.lock()
      let shouldEnqueue: Bool
      if renderJobScheduled {
        if renderJobRunning || frameNotificationPending {
          renderDirty = true
        }
        shouldEnqueue = false
      } else {
        renderJobScheduled = true
        shouldEnqueue = true
      }
      renderRequestLock.unlock()

      if shouldEnqueue {
        enqueueRenderJob()
      }
    }

    private func enqueueRenderJob() {
      worker.enqueue {
        self.performRenderJob()
      }
    }

    private func performRenderJob() {
      renderRequestLock.lock()
      renderJobRunning = true
      renderRequestLock.unlock()

      let result = renderFrame()

      renderRequestLock.lock()
      renderJobRunning = false
      let shouldEnqueue: Bool
      if result != nil {
        frameNotificationPending = true
        shouldEnqueue = false
      } else {
        shouldEnqueue = completeRenderCycleLocked()
      }
      renderRequestLock.unlock()

      if shouldEnqueue {
        enqueueRenderJob()
      }

      if let result = result {
        DispatchQueue.main.async { [weak self] in
          guard let that = self else { return }
          if !that.disposed && that.textureId >= 0 {
            that.publishTextureFrame(result)
          }
          that.completeRenderCycle()
        }
      }
    }

    private func completeRenderCycle() {
      renderRequestLock.lock()
      let shouldEnqueue = completeRenderCycleLocked()
      renderRequestLock.unlock()

      if shouldEnqueue {
        enqueueRenderJob()
      }
    }

    private func completeRenderCycleLocked() -> Bool {
      frameNotificationPending = false
      if renderDirty {
        renderDirty = false
        return true
      }
      renderJobScheduled = false
      return false
    }

    private func renderFrame() -> RenderResult? {
      if disposed {
        return nil
      }

      let size = videoSize

      if size.width == 0 || size.height == 0 {
        return nil
      }

      let sizeChanged = currentSize != size
      if sizeChanged {
        texture.resize(size)
      }

      if !texture.render(size) {
        return nil
      }

      hasRenderedFrame = true
      if sizeChanged {
        currentSize = size
      }

      return RenderResult(resizedTo: sizeChanged ? size : nil)
    }

    // Must be run on the main thread.
    private func publishTextureFrame(_ result: RenderResult) {
      registry.textureFrameAvailable(textureId)
      if let textureSize = result.resizedTo {
        textureUpdateCallback(textureId, textureSize)
      }
    }
  #else
    private func updateSynchronously() {
      let size = videoSize

      if size.width == 0 || size.height == 0 {
        return
      }

      if currentSize != size {
        currentSize = size

        texture.resize(size)
        DispatchQueue.main.sync { [weak self] in
          guard let that = self else { return }
          that.textureUpdateCallback(that.textureId, size)
        }
      }

      if disposed {
        return
      }

      texture.render(size)
      DispatchQueue.main.sync { [weak self] in
        guard let that = self else { return }
        that.registry.textureFrameAvailable(that.textureId)
      }
    }
  #endif

    private var videoSize: CGSize {
        // fixed size
        if width != nil && height != nil {
            return CGSize(
                width: Double(width!),
                height: Double(height!)
            )
        }
        
        let params = MPVHelpers.getVideoOutParams(handle)
        return CGSize(
            width: Double(width ?? (params.rotate == 0 || params.rotate == 180
                                    ? params.dw
                                    : params.dh)),
            height: Double(height ?? (params.rotate == 0 || params.rotate == 180
                                      ? params.dh
                                      : params.dw))
        )
  }
}
