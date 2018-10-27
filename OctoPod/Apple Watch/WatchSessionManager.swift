import Foundation
import UIKit
import WatchConnectivity

class WatchSessionManager: NSObject, WCSessionDelegate, CloudKitPrinterDelegate {

    var printerManager: PrinterManager
    var octoprintClient: OctoPrintClient
    var session: WCSession?
    
    var delegates: Array<WatchSessionManagerDelegate> = []

    init(printerManager: PrinterManager, cloudKitPrinterManager: CloudKitPrinterManager, octoprintClient: OctoPrintClient) {
        self.printerManager = printerManager
        self.octoprintClient = octoprintClient
        super.init()
        
        // Listen to iCloud changes. Printers may be modified from iPad and
        // when iPhone gets notified then we will reach and push to Apple Watch
        cloudKitPrinterManager.delegates.append(self)
    }

    func start() {
        if (WCSession.isSupported()) {
            session = WCSession.default
            
            session!.delegate = self
            session!.activate()
        } else {
            NSLog("WatchConnectivity is not supported on this device")
        }
    }
    
    func pushPrinters() {
        do {
            try getSession()?.updateApplicationContext(encodePrinters())
        }
        catch {
            NSLog("Failed to push printers as ApplicationContext. Error: \(error)")
        }
    }

    // MARK: - WCSessionDelegate
    
    /** Called when the session has completed activation. If session state is WCSessionActivationStateNotActivated there will be an error with more details. */
    public func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        
    }
    
    
    /** Called when the session can no longer be used to modify or add any new transfers and, all interactive messages will be cancelled, but delegate callbacks for background transfers can still occur. This will happen when the selected watch is being changed. */
    public func sessionDidBecomeInactive(_ session: WCSession) {
        
    }
    
    
    /** Called when all delegate callbacks for the previously selected watch has occurred. The session can be re-activated for the now selected watch using activateSession. */
    public func sessionDidDeactivate(_ session: WCSession) {
        
    }
    
    /** Called on the delegate of the receiver. Will be called on startup if the incoming message caused the receiver to launch. */
    public func session(_ session: WCSession, didReceiveMessage message: [String : Any]) {
        if message["start_print"] != nil {
            // Apple Watch requested to start new print job
            if let file = message["start_print"] as! String? {
                NSLog("Requesting to start printing file: \(file)")
            }
        } else {
            // Unkown request was received
            NSLog("Unknown request was received: \(message)")
        }
        
    }
    
    /** Called on the delegate of the receiver when the sender sends a message that expects a reply. Will be called on startup if the incoming message caused the receiver to launch. */
    public func session(_ session: WCSession, didReceiveMessage message: [String : Any], replyHandler: @escaping ([String : Any]) -> Void) {
        if message["printers"] != nil {
            replyHandler(encodePrinters())
        } else if message["panel_info"] != nil {
            panel_info(replyHandler)
        } else if message["pause_job"] != nil {
            pause_job(replyHandler)
        } else if message["resume_job"] != nil {
            resume_job(replyHandler)
        } else if message["cancel_job"] != nil {
            cancel_job(replyHandler)
        } else {
            // Unkown request was received
            let reply = ["unknown" : ""]
            replyHandler(reply)
            NSLog("Unknown request for a response was received: \(message)")
        }
    }
    
    /** Called on the delegate of the receiver. Will be called on startup if an applicationContext is available. */
    public func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String : Any]) {
        if applicationContext["selected_printer"] != nil {
            // Apple Watch marked a printer as the new selected on
            if let printer = printerManager.getPrinterByName(name: applicationContext["selected_printer"] as! String) {
                // Update stored printers
                printerManager.changeToDefaultPrinter(printer)
                // Ask octoprintClient to connect to new OctoPrint server
                octoprintClient.connectToServer(printer: printer)
                // Notify listeners of this change
                for delegate in delegates {
                    delegate.defaultPrinterChanged()
                }
            }
        }
    }

    // MARK: - CloudKitPrinterDelegate
    
    func printersUpdated() {
        pushPrinters()
    }
    
    func printerAdded(printer: Printer) {
    }
    
    func printerUpdated(printer: Printer) {
    }
    
    func printerDeleted(printer: Printer) {
    }
    
    // MARK: - Delegates operations
    
    func remove(watchSessionManagerDelegate toRemove: WatchSessionManagerDelegate) {
        delegates.removeAll(where: { $0 === toRemove })
    }

    // MARK: - Commands private functions

    fileprivate func panel_info(_ replyHandler: @escaping ([String : Any]) -> Void) {
        octoprintClient.currentJobInfo { (result: NSObject?, error: Error?, response :HTTPURLResponse) in
            if let error = error {
                replyHandler(["error": error.localizedDescription])
            } else if let result = result as? Dictionary<String, Any> {
                var reply: [String : Any] = [:]
                if let state = result["state"] as? String {
                    reply["state"] = state
                }
                if let progress = result["progress"] as? Dictionary<String, Any> {
                    if let completion = progress["completion"] as? Double {
                        reply["completion"] = completion
                    }
                    if let printTimeLeft = progress["printTimeLeft"] as? Int {
                        reply["printTimeLeft"] = printTimeLeft
                    }
                }
                
                // Gather now info about printer (paused/printing/temps)
                self.octoprintClient.printerState { (result: NSObject?, error: Error?, response: HTTPURLResponse) in
                    if let json = result as? NSDictionary {
                        let event = CurrentStateEvent()
                        if let state = json["state"] as? NSDictionary {
                            event.parseState(state: state)

                            if event.printing  == true {
                                reply["printer"] = "printing"
                            } else if event.paused == true {
                                reply["printer"] = "paused"
                            } else if event.operational == true {
                                reply["printer"] = "operational"
                            }                            
                        }
                        if let temps = json["temperature"] as? NSDictionary {
                            event.parseTemps(temp: temps)

                            if let bedTemp = event.bedTempActual {
                                reply["bedTemp"] = bedTemp
                            }
                            if let tool0Temp = event.tool0TempActual {
                                reply["tool0Temp"] = tool0Temp
                            }
                            if let tool1Temp = event.tool1TempActual {
                                reply["tool1Temp"] = tool1Temp
                            }
                        }
                    }
                    // Send reply back to Apple Watch with results
                    replyHandler(reply)
                }
            } else {
                if response.statusCode == 403 {
                    // Bad API Keys
                    replyHandler(["error": NSLocalizedString("Incorrect API Key", comment: "")])
                } else {
                    let message = String(format: NSLocalizedString("HTTP Request error", comment: "HTTP Request error info"), response.statusCode)
                    replyHandler(["error": message])
                }
            }
        }
    }
    
    fileprivate func pause_job(_ replyHandler: @escaping ([String : Any]) -> Void) {
        self.octoprintClient.pauseCurrentJob { (requested: Bool, error: Error?, response: HTTPURLResponse) in
            if requested {
                replyHandler(["" : ""])
            } else {
                replyHandler(["error" : error == nil ? "Failed with no error!!" : error!.localizedDescription])
            }
        }
    }

    fileprivate func resume_job(_ replyHandler: @escaping ([String : Any]) -> Void) {
        self.octoprintClient.resumeCurrentJob { (requested: Bool, error: Error?, response: HTTPURLResponse) in
            if requested {
                replyHandler(["" : ""])
            } else {
                replyHandler(["error" : error == nil ? "Failed with no error!!" : error!.localizedDescription])
            }
        }
    }

    fileprivate func cancel_job(_ replyHandler: @escaping ([String : Any]) -> Void) {
        self.octoprintClient.cancelCurrentJob { (requested: Bool, error: Error?, response: HTTPURLResponse) in
            if requested {
                replyHandler(["" : ""])
            } else {
                replyHandler(["error" : error == nil ? "Failed with no error!!" : error!.localizedDescription])
            }
        }
    }

    // MARK: - Private functions
    
    fileprivate func getSession() -> WCSession? {
        if let session = session {
            // Check that Apple Watch is paired and app is installed
            if !session.isPaired {
                print("Apple Watch is not paired")
            } else if !session.isWatchAppInstalled {
                print("WatchKit app is not installed")
            } else {
                return session
            }
        }
        return nil
    }
    
    fileprivate func encodePrinters() -> [String: [[String : Any]]] {
        var printers: [[String : Any]] = []
        for printer in printerManager.getPrinters() {
            var printerDic = ["name": printer.name, "hostname": printer.hostname, "apiKey": printer.apiKey, "isDefault": printer.defaultPrinter] as [String : Any]
            if let username = printer.username {
                printerDic["username"] = username
            }
            if let password = printer.password {
                printerDic["password"] = password
            }
            if let cameras = printer.cameras {
                var camerasArray: Array<Dictionary<String, Any>> = []
                for url in cameras {
                    var cameraURL: String
                    var cameraOrientation: Int
                    if url == printer.getStreamPath() {
                        // This is camera hosted by OctoPrint so respect orientation
                        cameraURL = octoPrintCameraAbsoluteUrl(hostname: printer.hostname, streamUrl: url)
                        cameraOrientation = Int(printer.cameraOrientation)
                    } else {
                        if url.starts(with: "/") {
                            // Another camera hosted by OctoPrint so build absolute URL
                            cameraURL = octoPrintCameraAbsoluteUrl(hostname: printer.hostname, streamUrl: url)
                        } else {
                            // Use absolute URL to render camera
                            cameraURL = url
                        }
                        cameraOrientation = UIImage.Orientation.up.rawValue // MultiCam has no information about orientation of extra cameras so assume "normal" position - no flips
                    }
                    let cameraDic = ["url" : cameraURL, "orientation": cameraOrientation] as [String : Any]                    
                    camerasArray.append(cameraDic)
                }
                printerDic["cameras"] = camerasArray
            }
            printers.append(printerDic)
        }
        
        NSLog("Encoded printers: \(["printers" : printers])")
        
        return ["printers" : printers]
    }
    
    fileprivate func octoPrintCameraAbsoluteUrl(hostname: String, streamUrl: String) -> String {
        if streamUrl.isEmpty {
            // Should never happen but let's be cautious
            return hostname
        }
        if streamUrl.starts(with: "/") {
            // Build absolute URL from relative URL
            return hostname + streamUrl
        }
        // streamURL is an absolute URL so return it
        return streamUrl
    }
}
