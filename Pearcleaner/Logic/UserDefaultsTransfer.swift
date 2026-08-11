//
//  UserDefaultsTransfer.swift
//  Pearcleaner
//
//  Safe JSON round-tripping for exported settings.
//

import Foundation

enum UserDefaultsTransferError: LocalizedError {
    case unsupportedValue(key: String, type: Any.Type)
    case invalidDocument
    case invalidTaggedValue(type: String)
    case nullValue

    var errorDescription: String? {
        switch self {
        case let .unsupportedValue(key, type):
            return "The setting \(key) contains an unsupported value of type \(type)."
        case .invalidDocument:
            return "The selected file is not a valid Onglai settings export."
        case let .invalidTaggedValue(type):
            return "The settings export contains an invalid \(type) value."
        case .nullValue:
            return "The settings export contains a null value, which UserDefaults cannot store."
        }
    }
}

enum UserDefaultsTransfer {
    private static let formatVersion = 1
    private static let typeKey = "__onglaiType"
    private static let valueKey = "value"

    static func exportData(from defaults: [String: Any]) throws -> Data {
        let settings = defaults.filter { $0.key.hasPrefix("settings.") }
        var encodedSettings: [String: Any] = [:]

        for (key, value) in settings {
            guard let encodedValue = encode(value) else {
                throw UserDefaultsTransferError.unsupportedValue(key: key, type: Swift.type(of: value))
            }
            encodedSettings[key] = encodedValue
        }

        let document: [String: Any] = [
            "formatVersion": formatVersion,
            "settings": encodedSettings,
        ]
        guard JSONSerialization.isValidJSONObject(document) else {
            throw UserDefaultsTransferError.invalidDocument
        }
        return try JSONSerialization.data(withJSONObject: document, options: [.prettyPrinted, .sortedKeys])
    }

    static func importSettings(from data: Data) throws -> [String: Any] {
        guard let document = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw UserDefaultsTransferError.invalidDocument
        }

        // Accept the pre-versioned format, which stored settings directly at
        // the top level, as well as the safe versioned envelope.
        let encodedSettings: [String: Any]
        if document["formatVersion"] != nil || document["settings"] != nil {
            guard let version = document["formatVersion"] as? NSNumber,
                  version.intValue == formatVersion,
                  let settings = document["settings"] as? [String: Any] else {
                throw UserDefaultsTransferError.invalidDocument
            }
            encodedSettings = settings
        } else {
            encodedSettings = document
        }

        var settings: [String: Any] = [:]
        for (key, value) in encodedSettings where key.hasPrefix("settings.") {
            settings[key] = try decode(value)
        }
        return settings
    }

    private static func encode(_ value: Any) -> Any? {
        switch value {
        case let data as Data:
            return [typeKey: "data", valueKey: data.base64EncodedString()]
        case let date as Date:
            return [typeKey: "date", valueKey: date.timeIntervalSince1970]
        case let url as URL:
            return [typeKey: "url", valueKey: url.absoluteString]
        case let array as [Any]:
            var encodedArray: [Any] = []
            for item in array {
                guard let encodedItem = encode(item) else { return nil }
                encodedArray.append(encodedItem)
            }
            return encodedArray
        case let dictionary as [String: Any]:
            var encodedDictionary: [String: Any] = [:]
            for (key, item) in dictionary {
                guard let encodedItem = encode(item) else { return nil }
                encodedDictionary[key] = encodedItem
            }
            return encodedDictionary
        case is String, is NSNumber, is NSNull:
            return value
        default:
            return nil
        }
    }

    private static func decode(_ value: Any) throws -> Any {
        if value is NSNull {
            throw UserDefaultsTransferError.nullValue
        }

        if let array = value as? [Any] {
            return try array.map(decode)
        }

        guard let dictionary = value as? [String: Any] else {
            return value
        }

        if dictionary.count == 2,
           dictionary[valueKey] != nil,
           let type = dictionary[typeKey] as? String {
            switch type {
            case "data":
                guard let base64 = dictionary[valueKey] as? String,
                      let data = Data(base64Encoded: base64) else {
                    throw UserDefaultsTransferError.invalidTaggedValue(type: type)
                }
                return data
            case "date":
                guard let interval = dictionary[valueKey] as? NSNumber else {
                    throw UserDefaultsTransferError.invalidTaggedValue(type: type)
                }
                return Date(timeIntervalSince1970: interval.doubleValue)
            case "url":
                guard let string = dictionary[valueKey] as? String,
                      let url = URL(string: string) else {
                    throw UserDefaultsTransferError.invalidTaggedValue(type: type)
                }
                return url
            default:
                throw UserDefaultsTransferError.invalidTaggedValue(type: type)
            }
        }

        var decodedDictionary: [String: Any] = [:]
        for (key, item) in dictionary {
            decodedDictionary[key] = try decode(item)
        }
        return decodedDictionary
    }
}
