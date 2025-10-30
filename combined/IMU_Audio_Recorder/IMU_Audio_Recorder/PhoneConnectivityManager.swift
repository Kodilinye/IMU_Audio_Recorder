import Foundation
import WatchConnectivity

class PhoneConnectivityManager: NSObject, WCSessionDelegate {
    var session: WCSession?
    
    override init() {
        super.init()
        print("\(Date()): --- PHONE: PhoneConnectivityManager initialized ---")
        
        if WCSession.isSupported() {
            session = WCSession.default
            session?.delegate = self
            session?.activate()
            print("\(Date()): --- PHONE: WCSession activated ---")
        } else {
            print("\(Date()): --- PHONE: WCSession not supported ---")
        }
    }
    
    func session(_ session: WCSession, didReceive file: WCSessionFile) {
        print("\(Date()): --- PHONE: Received file at \(file.fileURL.path) ---")
        
        guard let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            print("\(Date()): --- PHONE: CRITICAL ERROR - No documents directory ---")
            return
        }
        
        let destinationURL = documentsURL.appendingPathComponent(file.fileURL.lastPathComponent)
        
        do {
            if FileManager.default.fileExists(atPath: destinationURL.path) {
                try FileManager.default.removeItem(at: destinationURL)
                print("\(Date()): --- PHONE: Deleted existing file ---")
            }
            
            try FileManager.default.moveItem(at: file.fileURL, to: destinationURL)
            print("\(Date()): --- PHONE: SUCCESS! Moved file to \(destinationURL.path) ---")
        } catch {
            print("\(Date()): --- PHONE: CRITICAL ERROR - File move failed: \(error.localizedDescription) ---")
        }
    }
    
    func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        if let error = error {
            print("\(Date()): --- PHONE: Activation failed: \(error.localizedDescription) ---")
            return
        }
        
        switch activationState {
        case .activated: print("\(Date()): --- PHONE: Session activated ---")
        case .inactive: print("\(Date()): --- PHONE: Session inactive ---")
        case .notActivated: print("\(Date()): --- PHONE: Session not activated ---")
        @unknown default: print("\(Date()): --- PHONE: Session unknown state ---")
        }
    }
    
    func sessionReachabilityDidChange(_ session: WCSession) {
        print("\(Date()): --- PHONE: Reachability changed: \(session.isReachable ? "Reachable" : "Unreachable") ---")
    }
    
    func sessionDidBecomeInactive(_ session: WCSession) {
        print("\(Date()): --- PHONE: Session became inactive ---")
    }
    
    func sessionDidDeactivate(_ session: WCSession) {
        print("\(Date()): --- PHONE: Session deactivated - Reactivating ---")
        WCSession.default.activate()
    }
}
