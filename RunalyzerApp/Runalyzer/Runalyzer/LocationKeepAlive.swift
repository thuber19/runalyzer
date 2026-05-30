import Foundation
import CoreLocation

/// Requests location updates during recording to keep the app alive in background.
/// Also captures route data as a bonus.
class LocationKeepAlive: NSObject, ObservableObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()

    @Published var isTracking = false
    @Published var routePoints: [CLLocationCoordinate2D] = []
    @Published var totalDistanceMeters: Double = 0

    private var lastLocation: CLLocation?

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
        manager.allowsBackgroundLocationUpdates = true
        manager.pausesLocationUpdatesAutomatically = false
        manager.showsBackgroundLocationIndicator = true
    }

    func requestPermission() {
        manager.requestWhenInUseAuthorization()
        // Need "always" for reliable background, but "when in use" works
        // if background location indicator is shown
    }

    func startTracking() {
        routePoints.removeAll()
        totalDistanceMeters = 0
        lastLocation = nil
        manager.startUpdatingLocation()
        isTracking = true
    }

    func stopTracking() {
        manager.stopUpdatingLocation()
        isTracking = false
    }

    // MARK: - CLLocationManagerDelegate
    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        for location in locations {
            guard location.horizontalAccuracy < 50 else { continue } // skip inaccurate

            routePoints.append(location.coordinate)

            if let last = lastLocation {
                totalDistanceMeters += location.distance(from: last)
            }
            lastLocation = location
        }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        print("Location error: \(error.localizedDescription)")
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        print("Location auth: \(manager.authorizationStatus.rawValue)")
    }
}
