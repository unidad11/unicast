import Foundation
import Security

/// Guarda textos secretos (la clave de sincronización) en el llavero del iPhone, nunca en el código ni en ajustes.
enum Keychain {
    private static let servicio = "com.jbs.Unicast"

    private static func consulta(_ clave: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: servicio,
         kSecAttrAccount as String: clave]
    }

    static func save(_ valor: String, for clave: String) {
        SecItemDelete(consulta(clave) as CFDictionary)
        var nueva = consulta(clave)
        nueva[kSecValueData as String] = Data(valor.utf8)
        nueva[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(nueva as CFDictionary, nil)
    }

    static func load(_ clave: String) -> String? {
        var buscar = consulta(clave)
        buscar[kSecReturnData as String] = true
        buscar[kSecMatchLimit as String] = kSecMatchLimitOne
        var resultado: AnyObject?
        guard SecItemCopyMatching(buscar as CFDictionary, &resultado) == errSecSuccess,
              let datos = resultado as? Data else { return nil }
        return String(data: datos, encoding: .utf8)
    }

    static func delete(_ clave: String) {
        SecItemDelete(consulta(clave) as CFDictionary)
    }
}
