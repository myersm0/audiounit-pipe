import AVFoundation
import AudioToolbox
import Foundation

class AudioUnitManager {
	let audioUnit: AudioComponentInstance
	let outputFormat: AudioStreamBasicDescription
	let channelCount: UInt32
	let config: Config
	private var sampleTime: Float64 = 0
	private let renderLock = NSLock()
	private var velocityTable: VelocityTable? = nil
	
	init(config: Config) throws {
		self.config = config
		verboseLog("Searching for audio unit with subtype: \(config.componentSubType), manufacturer: \(config.componentManufacturer)")
		
		// Try multiple search strategies for macOS 26 compatibility
		var component: AudioComponent?
		
		// Strategy 1: Standard search
		var componentDescription = AudioComponentDescription(
			componentType: kAudioUnitType_MusicDevice,
			componentSubType: Self.makeFourCC(config.componentSubType),
			componentManufacturer: Self.makeFourCC(config.componentManufacturer),
			componentFlags: 0,
			componentFlagsMask: 0
		)
		
		component = AudioComponentFindNext(nil, &componentDescription)
		verboseLog("Strategy 1 (standard): \(component != nil ? "found" : "not found")")
		
		// Strategy 2: Search with sandbox-safe flag if Strategy 1 fails
		if component == nil {
			componentDescription.componentFlags = 0x00000001  // kAudioComponentFlag_SandboxSafe
			componentDescription.componentFlagsMask = 0x00000001
			component = AudioComponentFindNext(nil, &componentDescription)
			verboseLog("Strategy 2 (sandbox safe): \(component != nil ? "found" : "not found")")
		}
		
		// Strategy 3: Try iterating all components
		if component == nil {
			verboseLog("Strategy 3: Searching all available components...")
			componentDescription.componentFlags = 0
			componentDescription.componentFlagsMask = 0
			
			var currentComponent: AudioComponent? = nil
			while true {
				currentComponent = AudioComponentFindNext(currentComponent, &componentDescription)
				guard let comp = currentComponent else { break }
				
				var desc = AudioComponentDescription()
				AudioComponentGetDescription(comp, &desc)
				
				verboseLog("  Found component: type=\(Self.fourCCToString(desc.componentType)), sub=\(Self.fourCCToString(desc.componentSubType)), mfr=\(Self.fourCCToString(desc.componentManufacturer))")
				
				if desc.componentSubType == Self.makeFourCC(config.componentSubType) &&
				   desc.componentManufacturer == Self.makeFourCC(config.componentManufacturer) {
					component = comp
					verboseLog("Strategy 3: Match found!")
					break
				}
			}
		}
		
		// Strategy 4: List all music devices to help debug
		if component == nil {
			verboseLog("Strategy 4: Listing all available music devices...")
			var searchDesc = AudioComponentDescription(
				componentType: kAudioUnitType_MusicDevice,
				componentSubType: 0,
				componentManufacturer: 0,
				componentFlags: 0,
				componentFlagsMask: 0
			)
			
			var currentComponent: AudioComponent? = nil
			while true {
				currentComponent = AudioComponentFindNext(currentComponent, &searchDesc)
				guard let comp = currentComponent else { break }
				
				var desc = AudioComponentDescription()
				AudioComponentGetDescription(comp, &desc)
				
				var name: Unmanaged<CFString>?
				AudioComponentCopyName(comp, &name)
				let componentName = name?.takeRetainedValue() as String? ?? "Unknown"
				
				print("  Available: \(Self.fourCCToString(desc.componentSubType)) / \(Self.fourCCToString(desc.componentManufacturer)) - \(componentName)")
			}
		}
		
		guard let foundComponent = component else {
			throw AudioUnitError.componentNotFound(subtype: config.componentSubType, manufacturer: config.componentManufacturer)
		}
		
		verboseLog("Found audio unit component")
		
		// Create audio unit instance
		var audioUnit: AudioComponentInstance?
		let status = AudioComponentInstanceNew(foundComponent, &audioUnit)
		guard status == noErr, let au = audioUnit else {
			throw AudioUnitError.instantiationFailed(status: status)
		}
		
		self.audioUnit = au
		verboseLog("Audio unit instantiated successfully")
		
		// Get preferred format
		var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
		var outputFormat = AudioStreamBasicDescription()
		AudioUnitGetProperty(
			au,
			kAudioUnitProperty_StreamFormat,
			kAudioUnitScope_Output,
			0,
			&outputFormat,
			&size
		)
		
		self.outputFormat = outputFormat
		self.channelCount = outputFormat.mChannelsPerFrame
		
		print("Audio Unit's preferred format:")
		print("  Sample Rate: \(outputFormat.mSampleRate)")
		print("  Channels: \(outputFormat.mChannelsPerFrame)")
		print("  Bits per channel: \(outputFormat.mBitsPerChannel)")
		print("  Format flags: \(outputFormat.mFormatFlags)")
		print("  Output format: \(config.audioFormat == .planar ? "planar" : "interleaved")")
		
		// Set maximum frames per slice
		var maxFrames = config.bufferSize
		AudioUnitSetProperty(
			au,
			kAudioUnitProperty_MaximumFramesPerSlice,
			kAudioUnitScope_Global,
			0,
			&maxFrames,
			UInt32(MemoryLayout<UInt32>.size)
		)
		
		verboseLog("Set maximum frames per slice to \(maxFrames)")
		
		// Initialize the audio unit
		let initStatus = AudioUnitInitialize(au)
		if initStatus != noErr {
			throw AudioUnitError.initializationFailed(status: initStatus)
		}
		
		print("Audio Unit initialized successfully")
		
		// Give audio unit time to fully initialize
		Thread.sleep(forTimeInterval: 0.5)
		verboseLog("Audio Unit initialization complete")
		
		if let presetPath = config.presetPath {
			try restoreState(fromPresetPath: presetPath)
		}
		
		if let tablePath = config.velocityTablePath {
			velocityTable = try VelocityTable(path: tablePath)
		}
	}
	
	private func restoreState(fromPresetPath path: String) throws {
		let presetData: Data
		do {
			presetData = try Data(contentsOf: URL(fileURLWithPath: path))
		} catch {
			throw AudioUnitError.presetUnreadable(path: path, underlying: error)
		}
		
		guard let plist = try? PropertyListSerialization.propertyList(from: presetData, options: [], format: nil),
		      let preset = plist as? [String: Any] else {
			throw AudioUnitError.presetNotAPlist(path: path)
		}
		
		if let presetSubtype = (preset["subtype"] as? NSNumber)?.uint32Value,
		   presetSubtype != Self.makeFourCC(config.componentSubType) {
			print("Warning: preset subtype \(Self.fourCCToString(presetSubtype)) does not match loaded audio unit \(config.componentSubType)")
		}
		if let presetManufacturer = (preset["manufacturer"] as? NSNumber)?.uint32Value,
		   presetManufacturer != Self.makeFourCC(config.componentManufacturer) {
			print("Warning: preset manufacturer \(Self.fourCCToString(presetManufacturer)) does not match loaded audio unit \(config.componentManufacturer)")
		}
		
		var classInfo = plist as CFPropertyList?
		let status = withUnsafePointer(to: &classInfo) { pointer in
			AudioUnitSetProperty(
				audioUnit,
				kAudioUnitProperty_ClassInfo,
				kAudioUnitScope_Global,
				0,
				pointer,
				UInt32(MemoryLayout<CFPropertyList?>.size)
			)
		}
		guard status == noErr else {
			throw AudioUnitError.presetRestoreFailed(status: status)
		}
		
		let presetName = preset["name"] as? String ?? "(unnamed)"
		print("Restored preset '\(presetName)' from \(path)")
		print("Note: sample-based instruments may stream content for several seconds before rendering sound")
	}
	
	func processMIDIEvent(_ data: [UInt8]) {
		renderLock.lock()
		defer { renderLock.unlock() }
		
		if data.count == 3 {
			var bytes = data
			let status = bytes[0] & 0xF0
			let channel = bytes[0] & 0x0F
			
			if status == 0x90 && bytes[2] > 0, let table = velocityTable {
				let mapped = max(1, table.map(note: bytes[1], velocity: bytes[2]))
				verboseLog("Velocity remap - Note: \(bytes[1]), \(bytes[2]) -> \(mapped)")
				bytes[2] = mapped
			}
			
			MusicDeviceMIDIEvent(
				audioUnit,
				UInt32(bytes[0]),
				UInt32(bytes[1]),
				UInt32(bytes[2]),
				0
			)
			
			if status == 0x90 && bytes[2] > 0 {
				verboseLog("Note On - Channel: \(channel), Note: \(bytes[1]), Velocity: \(bytes[2])")
			} else if status == 0x80 || (status == 0x90 && bytes[2] == 0) {
				verboseLog("Note Off - Channel: \(channel), Note: \(bytes[1])")
			}
		}
	}
	
	func renderAudio(frames: UInt32) -> Data? {
		renderLock.lock()
		defer { renderLock.unlock() }
		
		var inTimeStamp = AudioTimeStamp()
		memset(&inTimeStamp, 0, MemoryLayout<AudioTimeStamp>.size)
		inTimeStamp.mSampleTime = sampleTime
		inTimeStamp.mFlags = .sampleTimeValid
		
		// Allocate buffers for actual channel count
		let audioBufferList = AudioBufferList.allocate(maximumBuffers: Int(channelCount))
		defer { audioBufferList.unsafeMutablePointer.deallocate() }
		
		for i in 0..<Int(channelCount) {
			audioBufferList[i] = AudioBuffer(
				mNumberChannels: 1,
				mDataByteSize: frames * 4,
				mData: malloc(Int(frames * 4))
			)
			memset(audioBufferList[i].mData, 0, Int(frames * 4))
		}
		
		defer {
			for i in 0..<Int(channelCount) {
				free(audioBufferList[i].mData)
			}
		}
		
		var ioActionFlags = AudioUnitRenderActionFlags()
		let renderStatus = AudioUnitRender(
			audioUnit,
			&ioActionFlags,
			&inTimeStamp,
			0,
			frames,
			audioBufferList.unsafeMutablePointer
		)
		
		if renderStatus == noErr {
			sampleTime += Float64(frames)
			
			// Format data based on config
			let outputData: Data
			
			switch config.audioFormat {
			case .interleaved:
				// Interleave all channels: frame0_ch0, frame0_ch1, ..., frame1_ch0, frame1_ch1, ...
				let totalSamples = Int(frames) * Int(channelCount)
				var interleavedData = Data(count: totalSamples * 4)
				
				interleavedData.withUnsafeMutableBytes { destPointer in
					guard let destBase = destPointer.baseAddress?.assumingMemoryBound(to: Float.self) else {
						return
					}
					
					// Get pointers to each channel's data
					var channelPointers: [UnsafePointer<Float>] = []
					for i in 0..<Int(channelCount) {
						if let data = audioBufferList[i].mData {
							channelPointers.append(data.assumingMemoryBound(to: Float.self))
						}
					}
					
					// Interleave: for each frame, copy all channel samples
					for frame in 0..<Int(frames) {
						for channel in 0..<Int(channelCount) {
							let destIndex = frame * Int(channelCount) + channel
							destBase[destIndex] = channelPointers[channel][frame]
						}
					}
				}
				outputData = interleavedData
				
			case .planar:
				// Concatenate channels: all of ch0, then all of ch1, etc.
				let bytesPerChannel = Int(frames) * 4
				var planarData = Data(count: bytesPerChannel * Int(channelCount))
				
				planarData.withUnsafeMutableBytes { destPointer in
					guard let destBase = destPointer.baseAddress?.assumingMemoryBound(to: Float.self) else {
						return
					}
					
					for channel in 0..<Int(channelCount) {
						if let channelData = audioBufferList[channel].mData {
							let sourcePointer = channelData.assumingMemoryBound(to: Float.self)
							let destOffset = channel * Int(frames)
							for frame in 0..<Int(frames) {
								destBase[destOffset + frame] = sourcePointer[frame]
							}
						}
					}
				}
				outputData = planarData
			}
			
			// Monitor audio level on first channel
			if let firstChannelData = audioBufferList[0].mData {
				let floatPointer = firstChannelData.assumingMemoryBound(to: Float.self)
				
				var maxSample: Float = 0
				var nonZeroCount = 0
				for i in 0..<Int(frames) {
					let sample = abs(floatPointer[i])
					if sample > maxSample && sample < 10.0 {
						maxSample = sample
					}
					if sample > 0.0 {
						nonZeroCount += 1
					}
				}
				
				if maxSample > 0.0001 {
					verboseLog("Audio level: \(maxSample), non-zero: \(nonZeroCount)/\(frames)")
				}
			}
			
			return outputData
		} else if renderStatus != -10878 {
			verboseLog("Render error: \(renderStatus)")
		}
		
		return nil
	}
	
	private static func makeFourCC(_ string: String) -> OSType {
		var result: OSType = 0
		for byte in string.utf8 {
			result = (result << 8) + OSType(byte)
		}
		return result
	}
	
	private static func fourCCToString(_ fourCC: OSType) -> String {
		let bytes: [UInt8] = [
			UInt8((fourCC >> 24) & 0xFF),
			UInt8((fourCC >> 16) & 0xFF),
			UInt8((fourCC >> 8) & 0xFF),
			UInt8(fourCC & 0xFF)
		]
		return String(bytes: bytes, encoding: .ascii) ?? "????"
	}
	
	deinit {
		AudioUnitUninitialize(audioUnit)
	}
}

enum AudioUnitError: Error {
	case componentNotFound(subtype: String, manufacturer: String)
	case instantiationFailed(status: OSStatus)
	case initializationFailed(status: OSStatus)
	case presetUnreadable(path: String, underlying: Error)
	case presetNotAPlist(path: String)
	case presetRestoreFailed(status: OSStatus)
}

extension AudioUnitError: LocalizedError {
	var errorDescription: String? {
		switch self {
		case .componentNotFound(let subtype, let manufacturer):
			return "Audio Unit not found with subtype '\(subtype)' and manufacturer '\(manufacturer)'"
		case .instantiationFailed(let status):
			return "Failed to instantiate Audio Unit: \(status)"
		case .initializationFailed(let status):
			return "AudioUnit initialization failed: \(status)"
		case .presetUnreadable(let path, let underlying):
			return "Could not read preset file at \(path): \(underlying.localizedDescription)"
		case .presetNotAPlist(let path):
			return "Preset file at \(path) is not a valid property list"
		case .presetRestoreFailed(let status):
			return "Failed to restore audio unit state from preset: \(status)"
		}
	}
}
