import Flutter
import AVFoundation

public class AVMediaPlayerPlugin: NSObject, FlutterPlugin {
  public static func register(with registrar: FlutterPluginRegistrar) {
    registrar.addMethodCallDelegate(
      AVMediaPlayerPlugin(registrar: registrar),
      channel: FlutterMethodChannel(
				name: "avMediaPlayer",
				binaryMessenger: registrar.messenger()
			)
    )
  }

  private var players: [Int64: AVMediaPlayer] = [:]
  private let registrar: FlutterPluginRegistrar

  init(registrar: FlutterPluginRegistrar) {
    self.registrar = registrar
    super.init()
  }

  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "create":
      let player = AVMediaPlayer(registrar: registrar)
      players[player.id] = player
      result(player.id)
    case "dispose":
      result(nil)
      if let id = call.arguments as? Int64 {
        players.removeValue(forKey: id)
      }
    case "open":
      result(nil)
      if let args = call.arguments as? [String: Any], let id = args["id"] as? Int64, let value = args["value"] as? String {
        players[id]?.open(source: value)
      }
    case "close":
      result(nil)
      if let id = call.arguments as? Int64 {
        players[id]?.close()
      }
    case "play":
      result(nil)
      if let id = call.arguments as? Int64 {
        players[id]?.play()
      }
    case "pause":
      result(nil)
      if let id = call.arguments as? Int64 {
        players[id]?.pause()
      }
    case "seekTo":
      result(nil)
      if let args = call.arguments as? [String: Any], let id = args["id"] as? Int64, let value = args["value"] as? Double {
				players[id]?.seekTo(pos: CMTime(seconds: value / 1000, preferredTimescale: 1000))
      }
    case "setVolume":
      result(nil)
      if let args = call.arguments as? [String: Any], let id = args["id"] as? Int64, let value = args["value"] as? Float {
        players[id]?.setVolume(vol: value)
      }
    case "setSpeed":
      result(nil)
      if let args = call.arguments as? [String: Any], let id = args["id"] as? Int64, let value = args["value"] as? Float {
        players[id]?.setSpeed(spd: value)
      }
    case "setLooping":
      result(nil)
      if let args = call.arguments as? [String: Any], let id = args["id"] as? Int64, let value = args["value"] as? Bool {
        players[id]?.setLooping(loop: value)
      }
    default:
      result(FlutterMethodNotImplemented)
    }
  }
}

class AVMediaPlayer: NSObject, FlutterTexture, FlutterStreamHandler {
  private let textureRegistry: FlutterTextureRegistry
  private let avPlayer = AVPlayer()

	var id: Int64!
  private var eventChannel: FlutterEventChannel!

	private var watcher: Any?
	private var displayLink: CADisplayLink?
  private var output: AVPlayerItemVideoOutput?
  private var eventSink: FlutterEventSink?
	private var position = CMTime.zero
	private var bufferPosition = CMTime.zero
  private var speed: Float = 1
  private var volume: Float = 1
  private var looping = false
	private var reading: CMTime?
  //0: idle, 1: opening, 2: ready, 3: playing
	private var state = 0
	private var source: String?

  init(registrar: FlutterPluginRegistrar) {
    textureRegistry = registrar.textures()
		super.init()
		id = textureRegistry.register(self)
		eventChannel = FlutterEventChannel(name: "avMediaPlayer/\(id!)", binaryMessenger: registrar.messenger())
    eventChannel.setStreamHandler(self)
    avPlayer.addObserver(self, forKeyPath: #keyPath(AVPlayer.currentItem.status), context: nil)
		avPlayer.addObserver(self, forKeyPath: #keyPath(AVPlayer.timeControlStatus), options: .old, context: nil)
		avPlayer.addObserver(self, forKeyPath: #keyPath(AVPlayer.currentItem.loadedTimeRanges), context: nil)
  }

  deinit {
    eventSink?(FlutterEndOfEventStream)
    eventChannel.setStreamHandler(nil)
    avPlayer.removeObserver(self, forKeyPath: #keyPath(AVPlayer.currentItem.status))
    avPlayer.removeObserver(self, forKeyPath: #keyPath(AVPlayer.timeControlStatus))
		avPlayer.removeObserver(self, forKeyPath: #keyPath(AVPlayer.currentItem.loadedTimeRanges))
    close()
		textureRegistry.unregisterTexture(id)
  }

  func open(source: String) {
    let uri = source.contains("://") ? URL(string: source) : URL(fileURLWithPath: source)
    if uri == nil {
      eventSink?(["event": "error", "value": "Invalid path"])
    } else {
      close()
			self.source = source
			state = 1
      avPlayer.replaceCurrentItem(with: AVPlayerItem(asset: AVAsset(url: uri!)))
      NotificationCenter.default.addObserver(
        self,
        selector: #selector(onFinish(notification:)),
        name: .AVPlayerItemDidPlayToEndTime,
        object: avPlayer.currentItem
      )
    }
  }

  func close() {
		state = 0
		position = .zero
		bufferPosition = .zero
		avPlayer.pause()
		if output != nil {
			avPlayer.currentItem?.remove(output!)
			output = nil
		}
		if displayLink != nil {
			displayLink!.invalidate()
			displayLink = nil
		}
		stopWatcher()
		source = nil
		reading = nil
		if avPlayer.currentItem != nil {
			NotificationCenter.default.removeObserver(
				self,
				name: .AVPlayerItemDidPlayToEndTime,
				object: avPlayer.currentItem
			)
			avPlayer.replaceCurrentItem(with: nil)
		}
  }

  func play() {
		if state > 1 {
			state = 3
			if watcher == nil {
				watcher = avPlayer.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.01, preferredTimescale: 1000), queue: nil) { [weak self] time in
					if self != nil {
						if self!.avPlayer.rate == 0 || self!.avPlayer.error != nil {
							self!.stopWatcher()
						}
						self!.setPosition(time: time)
					}
				}
			}
		  avPlayer.rate = speed
		}
  }

  func pause() {
		if state == 3 {
			state = 2
    	avPlayer.pause()
		}
  }

  func seekTo(pos: CMTime) {
    avPlayer.seek(to: pos, toleranceBefore: .zero, toleranceAfter: .zero) {[weak self] finished in
			if finished && self != nil {
				self!.eventSink?(["event": "seekEnd"])
				if self!.watcher == nil {
          self!.setPosition(time: self!.avPlayer.currentTime())
        }
      }
    }
  }

  func setVolume(vol: Float) {
    volume = vol
    avPlayer.volume = volume
  }

  func setSpeed(spd: Float) {
    speed = spd
    if avPlayer.rate > 0 {
      avPlayer.rate = speed
    }
  }

  func setLooping(loop: Bool) {
    looping = loop
  }
	
	private func stopWatcher() {
	  if watcher != nil {
		  avPlayer.removeTimeObserver(watcher!)
		  watcher = nil
	  }
	}
	
	private func setPosition(time: CMTime) {
		if time != position {
			position = time
			eventSink?(["event": "position", "value": Int(position.seconds * 1000)])
		}
	}
	
  func copyPixelBuffer() -> Unmanaged<CVPixelBuffer>? {
		if let t = reading {
			reading = nil
			if let buffer = output?.copyPixelBuffer(forItemTime: t, itemTimeForDisplay: nil) {
				return Unmanaged.passRetained(buffer)
			} else {
				return nil
			}
		} else {
			return nil
		}
  }
	
	@objc private func render() {
		if output != nil && displayLink != nil && reading == nil {
			let t = output!.itemTime(forHostTime: CACurrentMediaTime())
			if output!.hasNewPixelBuffer(forItemTime: t) {
				textureRegistry.textureFrameAvailable(id)
				reading = t
			}
		}
	}
	
	@objc private func onFinish(notification: NSNotification) {
	  avPlayer.seek(to: .zero) {[weak self] finished in
			if self != nil {
				if self!.looping && self!.state == 3 {
					self!.play()
				} else if finished {
					if self!.state == 3 {
						self!.state = 2
					}
					self!.position = .zero
					self!.bufferPosition = .zero
				}
				self!.eventSink?(["event": "finished"])
			}
	  }
  }

  func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
    eventSink = events
		return nil
  }

  func onCancel(withArguments arguments: Any?) -> FlutterError? {
    eventSink = nil
		return nil
  }

  override func observeValue(forKeyPath keyPath: String?, of object: Any?, change: [NSKeyValueChangeKey: Any]?, context: UnsafeMutableRawPointer?) {
		switch keyPath {
		case #keyPath(AVPlayer.currentItem.status):
			switch avPlayer.currentItem?.status {
			case .readyToPlay:
				if let currentItem = avPlayer.currentItem,
					source != nil {
					let width = Int(currentItem.presentationSize.width)
					let height = Int(currentItem.presentationSize.height)
					let duration = Int(currentItem.duration.seconds * 1000)
					if width > 0 && height > 0 && duration > 0 {
						output = AVPlayerItemVideoOutput(pixelBufferAttributes: nil)
						currentItem.add(output!)
						displayLink = CADisplayLink(target: self, selector: #selector(render))
						displayLink!.add(to: .current, forMode: .common)
					}
					avPlayer.volume = volume
					state = 2
					eventSink?([
						"event": "mediaInfo",
						"duration": duration,
						"width": width,
						"height": height,
						"source": source!
					])
				}
			case .failed:
				if state != 0 {
					eventSink?(["event": "error", "value": avPlayer.currentItem?.error?.localizedDescription ?? "Unknown error"])
					close()
				}
			default:
				break
			}
		case #keyPath(AVPlayer.timeControlStatus):
			if let oldValue = change?[NSKeyValueChangeKey.oldKey] as? Int,
				 let oldStatus = AVPlayer.TimeControlStatus(rawValue: oldValue),
				 oldStatus == .waitingToPlayAtSpecifiedRate || avPlayer.timeControlStatus == .waitingToPlayAtSpecifiedRate {
				eventSink?(["event": "loading", "value": avPlayer.timeControlStatus == .waitingToPlayAtSpecifiedRate])
			}
		case #keyPath(AVPlayer.currentItem.loadedTimeRanges):
			if let currentTime = avPlayer.currentItem?.currentTime(),
				 let timeRanges = avPlayer.currentItem?.loadedTimeRanges as? [CMTimeRange] {
				for timeRange in timeRanges {
					let end = timeRange.start + timeRange.duration
					if timeRange.start <= currentTime && end >= currentTime {
						if end != bufferPosition {
							bufferPosition = end
							eventSink?(["event": "bufferChange", "begin": Int(currentTime.seconds * 1000), "end": Int(bufferPosition.seconds * 1000)])
						}
						break
					}
				}
			}
		default:
			break
		}
  }
}
