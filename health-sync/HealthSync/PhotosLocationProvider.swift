import Foundation
import Photos
import CoreLocation

/// Use the user's geotagged photo library as a retroactive location index.
/// Every iPhone photo taken outdoors carries CLLocation in its metadata; for
/// any HK timestamp we just need a photo within a few hours to know roughly
/// where you were. Crude but works backwards in time, which CLLocationManager
/// fundamentally cannot.
///
/// Requires `NSPhotoLibraryUsageDescription` in Info.plist + Limited or Full
/// authorization. Read-only, no PHAsset modifications.
enum PhotosLocationProvider {

    static var authStatus: PHAuthorizationStatus {
        PHPhotoLibrary.authorizationStatus(for: .readWrite)
    }

    static func requestAuth() async -> PHAuthorizationStatus {
        await withCheckedContinuation { cont in
            PHPhotoLibrary.requestAuthorization(for: .readWrite) { cont.resume(returning: $0) }
        }
    }

    /// Every geotagged photo in [start, end]. Sorted ascending by creationDate
    /// so the caller can binary-search by timestamp.
    static func fetchGeotaggedPhotos(start: Date, end: Date) async -> [PhotoFix] {
        guard end > start else { return [] }
        // Make sure we have permission first; without it the fetch returns empty.
        let status = authStatus
        guard status == .authorized || status == .limited else { return [] }

        return await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                let opts = PHFetchOptions()
                opts.predicate = NSPredicate(
                    format: "creationDate >= %@ AND creationDate <= %@",
                    start as NSDate, end as NSDate
                )
                opts.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: true)]
                opts.includeAssetSourceTypes = .typeUserLibrary
                let assets = PHAsset.fetchAssets(with: .image, options: opts)
                var out: [PhotoFix] = []
                assets.enumerateObjects { asset, _, _ in
                    guard let loc = asset.location, let date = asset.creationDate else { return }
                    out.append(PhotoFix(date: date, location: loc))
                }
                cont.resume(returning: out)
            }
        }
    }
}

struct PhotoFix {
    let date: Date
    let location: CLLocation
}

/// Find the geotagged photo closest in time to `target` within `maxOffset`.
/// Sorted-ascending input expected. Returns nil if nothing's within the window.
func nearestPhoto(to target: Date, photos: [PhotoFix], maxOffset: TimeInterval) -> PhotoFix? {
    guard !photos.isEmpty else { return nil }
    // Binary search for the first photo >= target.
    var lo = 0, hi = photos.count
    while lo < hi {
        let mid = (lo + hi) / 2
        if photos[mid].date < target { lo = mid + 1 } else { hi = mid }
    }
    let candidates = [lo, lo - 1].filter { $0 >= 0 && $0 < photos.count }
    let best = candidates.min(by: {
        abs(photos[$0].date.timeIntervalSince(target)) < abs(photos[$1].date.timeIntervalSince(target))
    })
    guard let idx = best else { return nil }
    let p = photos[idx]
    return abs(p.date.timeIntervalSince(target)) <= maxOffset ? p : nil
}
