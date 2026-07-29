import Foundation

enum AudioFormat {
	case interleaved
	case planar
}

struct Config {
	let componentSubType: String
	let componentManufacturer: String
	let verbose: Bool
	let port: Int
	let host: String
	let rpcHost: String
	let rpcPort: Int
	let rpcEnabled: Bool
	let rpcPollInterval: Double
	let bufferSize: UInt32
	let audioFormat: AudioFormat
	let presetPath: String?
	
	static func parse() -> Config {
		let args = CommandLine.arguments
		
		var componentSubType = ""
		var componentManufacturer = ""
		var verbose = false
		var port = 9999
		var host = "127.0.0.1"
		var rpcHost = "127.0.0.1"
		var rpcPort = 8081
		var rpcEnabled = false
		var rpcPollInterval = 0.5
		var bufferSize: UInt32 = 512
		var audioFormat: AudioFormat = .interleaved
		var presetPath: String? = nil
		
		var i = 1
		while i < args.count {
			switch args[i] {
			case "-s", "--subtype":
				guard i + 1 < args.count else {
					fatalError("Missing value for --subtype")
				}
				componentSubType = args[i + 1]
				i += 2
			case "-m", "--manufacturer":
				guard i + 1 < args.count else {
					fatalError("Missing value for --manufacturer")
				}
				componentManufacturer = args[i + 1]
				i += 2
			case "-v", "--verbose":
				verbose = true
				i += 1
			case "-p", "--port":
				guard i + 1 < args.count else {
					fatalError("Missing value for --port")
				}
				port = Int(args[i + 1]) ?? 9999
				i += 2
			case "-h", "--host":
				guard i + 1 < args.count else {
					fatalError("Missing value for --host")
				}
				host = args[i + 1]
				i += 2
			case "--rpc-host":
				guard i + 1 < args.count else {
					fatalError("Missing value for --rpc-host")
				}
				rpcHost = args[i + 1]
				i += 2
			case "--rpc-port":
				guard i + 1 < args.count else {
					fatalError("Missing value for --rpc-port")
				}
				rpcPort = Int(args[i + 1]) ?? 8081
				i += 2
			case "--enable-rpc":
				rpcEnabled = true
				i += 1
			case "--rpc-poll-interval":
				guard i + 1 < args.count else {
					fatalError("Missing value for --rpc-poll-interval")
				}
				rpcPollInterval = Double(args[i + 1]) ?? 0.5
				i += 2
			case "--buffer-size":
				guard i + 1 < args.count else {
					fatalError("Missing value for --buffer-size")
				}
				bufferSize = UInt32(args[i + 1]) ?? 512
				i += 2
			case "--format":
				guard i + 1 < args.count else {
					fatalError("Missing value for --format")
				}
				switch args[i + 1].lowercased() {
				case "planar":
					audioFormat = .planar
				case "interleaved":
					audioFormat = .interleaved
				default:
					fatalError("Invalid format: \(args[i + 1]). Use 'planar' or 'interleaved'")
				}
				i += 2
			case "--preset":
				guard i + 1 < args.count else {
					fatalError("Missing value for --preset")
				}
				presetPath = args[i + 1]
				i += 2
			case "--help":
				printUsage()
				exit(0)
			default:
				print("Unknown argument: \(args[i])")
				printUsage()
				exit(1)
			}
		}
		
		if componentSubType.isEmpty || componentManufacturer.isEmpty {
			print("Error: Both --subtype and --manufacturer are required")
			printUsage()
			exit(1)
		}
		
		return Config(
			componentSubType: componentSubType,
			componentManufacturer: componentManufacturer,
			verbose: verbose,
			port: port,
			host: host,
			rpcHost: rpcHost,
			rpcPort: rpcPort,
			rpcEnabled: rpcEnabled,
			rpcPollInterval: rpcPollInterval,
			bufferSize: bufferSize,
			audioFormat: audioFormat,
			presetPath: presetPath
		)
	}
	
	private static func printUsage() {
		print("""
		Usage: AudioUnitHost [OPTIONS]
		
		Required:
		  -s, --subtype SUBTYPE           Audio unit subtype (e.g., "Pt9q")
		  -m, --manufacturer MANUFACTURER Audio unit manufacturer (e.g., "Mdrt")
		
		Optional:
		  -v, --verbose                   Enable verbose output
		  -p, --port PORT                 TCP port (default: 9999)
		  -h, --host HOST                 TCP host (default: 127.0.0.1)
		  --buffer-size SIZE              Audio buffer size in frames (default: 512)
		  --format FORMAT                 Audio format: 'interleaved' or 'planar' (default: interleaved)
		  --preset PATH                   Restore audio unit state from an .aupreset file
		  --enable-rpc                    Enable JSON-RPC monitoring
		  --rpc-host HOST                 JSON-RPC host (default: 127.0.0.1)
		  --rpc-port PORT                 JSON-RPC port (default: 8081)
		  --rpc-poll-interval SECONDS     RPC polling interval (default: 0.5)
		  --help                          Show this help message
		
		Example:
		  AudioUnitHost --subtype "Pt9q" --manufacturer "Mdrt" --verbose
		  AudioUnitHost --subtype "Pt9q" --manufacturer "Mdrt" --enable-rpc
		  AudioUnitHost --subtype "Pt9q" --manufacturer "Mdrt" --format planar
		  AudioUnitHost --subtype "UVIW" --manufacturer "UVI " --preset my-test-preset.aupreset
		""")
	}
}

// Global config instance
var globalConfig: Config!

func verboseLog(_ message: String) {
	if globalConfig.verbose {
		print("[VERBOSE] \(message)")
	}
}
