//
//  EventSource.swift
//  EventSource
//
//  Created by Andres on 2/13/15.
//  Copyright (c) 2015 Inaka. All rights reserved.
//

import Foundation

enum EventSourceState {
    case Connecting
    case Open
    case Closed
}

public class EventSource: NSObject, NSURLSessionDataDelegate{

    let url: NSURL
    private let urlSession: NSURLSession?
    private let task : NSURLSessionTask?
    private let operationQueue = NSOperationQueue()
    private let receivedString: NSString?
    private var lastEventID: NSString?
    private var onOpenCallback: (Void -> Void)?
    private var onErrorCallback: (Void -> Void)?
    private var onMessageCallback: ((id: String?, event: String?, data: String?) -> Void)?
    private(set) var readyState = EventSourceState.Closed
    private(set) var retryTime = 3000
    private var eventListeners = Dictionary<String, (id: String?, event: String?, data: String?) -> Void>()
    
    var event = Dictionary<String, String>()

    
    init(url: NSString, headers: [NSString : NSString]){

        self.url = NSURL(string: url)!
        
        var additionalHeaders = headers
        if let eventID = lastEventID{
            additionalHeaders["Last-Event-Id"] = eventID
        }

        additionalHeaders["Accept"] = "text/event-stream"
        additionalHeaders["Cache-Control"] = "no-cache"

        let configuration = NSURLSessionConfiguration.defaultSessionConfiguration()
        configuration.timeoutIntervalForRequest = NSTimeInterval(INT_MAX)
        configuration.timeoutIntervalForResource = NSTimeInterval(INT_MAX)
        configuration.HTTPAdditionalHeaders = additionalHeaders

        super.init();

        readyState = EventSourceState.Connecting
        urlSession = NSURLSession(configuration: configuration, delegate: self, delegateQueue: operationQueue)
        task = urlSession!.dataTaskWithURL(self.url);
        task!.resume()
    }
    
//Mark: Close
    
    func close(){
        readyState = EventSourceState.Closed
        urlSession?.invalidateAndCancel()
    }
    
//Mark: EventListeners
    
    func onOpen(onOpenCallback: Void -> Void) {
        self.onOpenCallback = onOpenCallback
    }

    func onError(onErrorCallback: Void -> Void) {
        self.onErrorCallback = onErrorCallback
    }
    
    func onMessage(onMessageCallback: (id: String?, event: String?, data: String?) -> Void){
        self.onMessageCallback = onMessageCallback
    }
    
    func addEventListener(event: String, handler: (id: String?, event: String?, data: String?) -> Void){
        self.eventListeners[event] = handler
    }

//MARK: NSURLSessionDataDelegate
    
    public func URLSession(session: NSURLSession, dataTask: NSURLSessionDataTask, didReceiveData data: NSData){
        if let receivedString = NSString(data: data, encoding: NSUTF8StringEncoding){
            parseEventStream(receivedString)
        }
    }

    func URLSession(session: NSURLSession!, dataTask: NSURLSessionDataTask, didReceiveResponse response: NSURLResponse, completionHandler: ((NSURLSessionResponseDisposition) -> Void)) {
        completionHandler(NSURLSessionResponseDisposition.Allow);

        readyState = EventSourceState.Open
        if(self.onOpenCallback != nil){
            dispatch_async(dispatch_get_main_queue()) {
                self.onOpenCallback!()
            }
        }
    }

    public func URLSession(session: NSURLSession, task: NSURLSessionTask, didCompleteWithError error: NSError?){
        readyState = EventSourceState.Closed
        if(self.onErrorCallback != nil){
            if(error?.domain != "NSURLErrorDomain" && error?.code != -999){
                dispatch_async(dispatch_get_main_queue()) {
                    self.onErrorCallback!()
                }
            }
        }
    }

//MARK: Helpers
    
    public func parseEventStream(events: String){
        var parsedEvents: [(id: String?, event: String?, data: String?)] = Array()

        let events = events.componentsSeparatedByString("\n\n")
        for event in events as [String]{

            if event.isEmpty {
                continue
            }

            if event.hasPrefix(":"){
                continue
            }

            if (event as NSString).containsString("retry:"){
                if let reconnectTime = parseRetryTime(event){
                    self.retryTime = reconnectTime
                }
                continue
            }

            parsedEvents.append(parseEvent(event))
        }

        for parsedEvent in parsedEvents as [(id: String?, event: String?, data: String?)]{
            self.lastEventID = parsedEvent.id
            
            if parsedEvent.event == nil && parsedEvent.data != nil {
                if(self.onMessageCallback != nil){
                    dispatch_async(dispatch_get_main_queue()) {
                        self.onMessageCallback!(id:self.lastEventID,event: "message",data: parsedEvent.data)
                    }
                }
            }
            
            if parsedEvent.event != nil && parsedEvent.data != nil {
                if (self.eventListeners[parsedEvent.event!] != nil){
                    dispatch_async(dispatch_get_main_queue()) {
                        let eventHandler = self.eventListeners[parsedEvent.event!]
                        eventHandler!(id:self.lastEventID,event:parsedEvent.event!, data: parsedEvent.data!)
                    }
                }
            }
        }
    }

    private func parseEvent(eventString: String) -> (id: String?, event: String?, data: String?){
        var event = Dictionary<String, String>()
        
        for line in eventString.componentsSeparatedByCharactersInSet(NSCharacterSet.newlineCharacterSet()) as [String]{
            autoreleasepool {
                var key: NSString?, value: NSString?
                let scanner = NSScanner(string: line)
                scanner.scanUpToString(":", intoString: &key)
                scanner.scanString(":",intoString: nil)
                scanner.scanUpToString("\n", intoString: &value)
                
                if (key != nil && value != nil) {
                    if (event[key!] != nil) {
                        event[key!] = "\(event[key!])\n\(value!)"
                    } else {
                        event[key!] = value!
                    }
                }
            }
        }

        print("Event: \(event)")
        
        return (event["id"], event["event"], event["data"])
    }

    private func parseRetryTime(eventString: String) -> Int?{
        var reconnectTime: Int?
        let separators = NSCharacterSet(charactersInString: ":")
        if let milli = eventString.componentsSeparatedByCharactersInSet(separators).last{
            let milliseconds = trim(milli)

            if let intMiliseconds = milliseconds.toInt() {
                reconnectTime = intMiliseconds
            }
        }
        return reconnectTime
    }

    private func trim(string: String) -> String{
        return string.stringByTrimmingCharactersInSet(NSCharacterSet.whitespaceCharacterSet())
    }

    class func basicAuth(username: NSString, password: NSString) -> NSString{
        let authString = "\(username):\(password)"
        let authData = authString.dataUsingEncoding(NSUTF8StringEncoding)
        let base64String = authData!.base64EncodedStringWithOptions(NSDataBase64EncodingOptions.Encoding76CharacterLineLength)

        return "Basic \(base64String)"
    }
}