import Foundation

final class VelocityTable {
	private let path: String
	private let lock = NSLock()
	private var table: [[UInt8]]
	private var lastModified: Date?
	private var watchTimer: DispatchSourceTimer?
	
	init(path: String) throws {
		self.path = path
		self.table = try Self.load(path: path)
		self.lastModified = Self.modificationDate(path: path)
		startWatching()
		print("Loaded velocity table from \(path)")
	}
	
	func map(note: UInt8, velocity: UInt8) -> UInt8 {
		lock.lock()
		defer { lock.unlock() }
		return table[Int(note & 0x7F)][Int(velocity & 0x7F)]
	}
	
	private func startWatching() {
		let timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "velocity.table.watch", qos: .utility))
		timer.schedule(deadline: .now() + 0.5, repeating: 0.5)
		timer.setEventHandler { [weak self] in
			self?.reloadIfChanged()
		}
		timer.resume()
		self.watchTimer = timer
	}
	
	private func reloadIfChanged() {
		guard let modified = Self.modificationDate(path: path), modified != lastModified else {
			return
		}
		lastModified = modified
		do {
			let newTable = try Self.load(path: path)
			lock.lock()
			table = newTable
			lock.unlock()
			print("Reloaded velocity table")
		} catch {
			print("Warning: velocity table reload failed, keeping previous table: \(error.localizedDescription)")
		}
	}
	
	private static func modificationDate(path: String) -> Date? {
		(try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
	}
	
	private static func load(path: String) throws -> [[UInt8]] {
		let data = try Data(contentsOf: URL(fileURLWithPath: path))
		guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
		      let rows = json["table"] as? [[NSNumber]],
		      rows.count == 128,
		      rows.allSatisfy({ $0.count == 128 }) else {
			throw VelocityTableError.invalidFormat(path: path)
		}
		return rows.map { row in
			row.map { UInt8(clamping: min(127, max(0, $0.intValue))) }
		}
	}
}

enum VelocityTableError: Error, LocalizedError {
	case invalidFormat(path: String)
	
	var errorDescription: String? {
		switch self {
		case .invalidFormat(let path):
			return "Velocity table at \(path) must be JSON with a 'table' field of 128 rows of 128 entries"
		}
	}
}
