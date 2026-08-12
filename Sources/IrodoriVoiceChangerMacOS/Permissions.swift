import AVFoundation
import Foundation

public enum PermissionState: String, Equatable, Sendable {
    case notDetermined = "not_determined"
    case denied
    case restricted
    case authorized
}

public enum AppPermissions {
    public static var microphone: PermissionState {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .notDetermined: .notDetermined
        case .restricted: .restricted
        case .denied: .denied
        case .authorized: .authorized
        @unknown default: .denied
        }
    }

    public static func requestMicrophone() async -> PermissionState {
        _ = await AVCaptureDevice.requestAccess(for: .audio)
        return microphone
    }
}
