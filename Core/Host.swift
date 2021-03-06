//
//  Host.swift
//  MKNetworkKit
//
//  Created by Mugunth Kumar
//  Copyright © 2015 - 2020 Steinlogic Consulting and Training Pte Ltd. All rights reserved.
//
//  MIT LICENSE (REQUIRES ATTRIBUTION)
//	ATTRIBUTION FREE LICENSING AVAILBLE (for a license fee)
//  Email mugunth.kumar@gmail.com for details
//
//  Created by Mugunth Kumar (@mugunthkumar)
//  Copyright (C) 2015-2025 by Steinlogic Consulting And Training Pte Ltd.

//  Permission is hereby granted, free of charge, to any person obtaining a copy
//  of this software and associated documentation files (the "Software"), to deal
//  in the Software without restriction, including without limitation the rights
//  to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
//  copies of the Software, and to permit persons to whom the Software is
//  furnished to do so, subject to the following conditions:
//
//  The above copyright notice and this permission notice shall be included in
//  all copies or substantial portions of the Software.
//
//  THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
//  IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
//  FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
//  AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
//  LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
//  OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
//  THE SOFTWARE.


import Foundation

let DefaultCacheDuration:NSTimeInterval = 60 // 1 minute

public class Host: NSObject, NSURLSessionTaskDelegate, NSURLSessionDownloadDelegate {

  var defaultSession: NSURLSession!
  private var ephermeralSession: NSURLSession!

  private var backgroundSession: NSURLSession!
  public var backgroundSessionCompletionHandler: (Void -> Void)?
  public var backgroundSessionIdentifier: String = "com.mknetworkkit.backgroundsessionidentifier"

  private var defaultHeaders: [String:String]

  var authenticationHandler: ((session: NSURLSession, task: NSURLSessionTask,  challenge: NSURLAuthenticationChallenge, completionHandler: (NSURLSessionAuthChallengeDisposition, NSURLCredential?) -> Void) -> Void)?

  public var name: String?
  private var path: String?
  private var portNumber: Int?

  public var cacheDirectory: String? {
    didSet {
      if let unwrappedDirectory = cacheDirectory {
        dataCache = Cache(directoryName: "\(unwrappedDirectory)/Data")
        responseCache = Cache(directoryName: "\(unwrappedDirectory)/Response")
      }
    }
  }

  private var dataCache: Cache<NSData>?
  private var responseCache: Cache<NSHTTPURLResponse>?

  func emptyCache() {
    dataCache?.emptyCache()
    responseCache?.emptyCache()
  }

  public var secure: Bool = true // ATS, so true! Yay!

  public init(name: String? = nil,
    path: String? = nil,
    defaultHeaders: [String:String] = [:],
    portNumber: Int? = nil,
    session: NSURLSession? = nil,
    cacheDirectory: String? = nil) {

      self.name = name
      self.defaultHeaders = defaultHeaders
      self.path = path
      self.portNumber = portNumber

      if let unwrappedDirectory = cacheDirectory {
        self.cacheDirectory = unwrappedDirectory
        dataCache = Cache(directoryName: "\(unwrappedDirectory)/Data")
        responseCache = Cache(directoryName: "\(unwrappedDirectory)/Response")
      }

      super.init()

      if let s = session {
        defaultSession = s
      } else {
        defaultSession = NSURLSession(configuration:
          NSURLSessionConfiguration.defaultSessionConfiguration(),
          delegate: self, delegateQueue: NSOperationQueue.mainQueue())
      }

      ephermeralSession = NSURLSession(configuration: NSURLSessionConfiguration.ephemeralSessionConfiguration(),
        delegate: self, delegateQueue: NSOperationQueue.mainQueue())

      if let name = name {
        backgroundSessionIdentifier = "com.mknetworkkit.backgroundsessionidentifier.\(name)"
      }

      let configuration = NSURLSessionConfiguration.backgroundSessionConfigurationWithIdentifier(backgroundSessionIdentifier)
      backgroundSession = NSURLSession(configuration: configuration,
        delegate: self, delegateQueue: NSOperationQueue.mainQueue())
  }

  public func request(withUrlString urlString: String) -> Request {
    let request = Request(url: urlString)
    request.host = self
    return request
  }

  public func request(
    method: HTTPMethod = .GET,
    withPath requestPath: String,
    parameters: [String:AnyObject] = [:],
    headers: [String:String] = [:],
    bodyData: NSData? = nil,
    ssl: Bool? = nil) -> Request? {

      var httpProtocol: String!

      if let unwrappedSSL = ssl {
        httpProtocol = unwrappedSSL ? "https://" : "http://"
      } else {
        httpProtocol = secure ? "https://" : "http://"
      }

      guard let hostName = name else {
        Log.error("Host name is nil. To create a request with absolute URL use request(withUrlString:)")
        return nil
      }

      var finalUrl: String = httpProtocol + hostName

      if let unwrappedPortNumber = portNumber {
        finalUrl = finalUrl + ":\(unwrappedPortNumber)"
      }

      if let unwrappedPath = self.path {
        finalUrl = finalUrl + "/\(unwrappedPath)"
      }

      finalUrl = finalUrl + "/\(requestPath)"

      let request = Request(
        method: method,
        url: finalUrl,
        parameters: parameters,
        headers: headers,
        bodyData: bodyData)

      request.host = self // weak reference
      request.append(headers: defaultHeaders)
      return customizeRequest(request)
  }

  public func customizeRequest(request: Request) -> Request {
    if !request.cacheble || request.ignoreCache {
      return request
    }
    if let cachedResponse = responseCache?[request.equalityIdentifier] {
      if let lastModified = cachedResponse.headerValue("Last-Modified") {
        request.appendHeader("IF-MODIFIED-SINCE", value: lastModified)
      }
      if let eTag = cachedResponse.headerValue("ETag") {
        request.appendHeader("IF-NONE-MATCH", value: eTag)
      }
    }
    return request
  }

  public func customizeError(request: Request) -> NSError? {
    return request.error
  }

  public func startDownloadRequest(request: Request) {
    guard let urlRequest = request.request else {
      Log.error("Request is nil, check your URL and other parameters you use to build your request")
      return
    }

//    if backgroundSessionCompletionHandler == nil {
//      print("application:handleEventsForBackgroundURLSession:completionHandler: is not implemented in your application delegate. Download tasks will not resume properly after the app is backgrounded. Implement the method and set the completionHandler value to the host's backgroundSessionCompletionHandler")
//    }
    request.task = backgroundSession.downloadTaskWithRequest(urlRequest)
    request.task!.request = request
    request.state = .Started
  }

  public func startRequest(request: Request) {
    guard let urlRequest = request.request else {
      Log.error("Request is nil, check your URL and other parameters you use to build your request")
      return
    }

    if request.cacheble && !request.ignoreCache {
      if let cachedResponse = responseCache?[request.equalityIdentifier] {
        let cacheExpiryDate = cachedResponse.cacheExpiryDate
        let expiryTimeFromNow = cacheExpiryDate?.timeIntervalSinceNow ?? DefaultCacheDuration

        if let data = dataCache?[request.equalityIdentifier] {
          request.responseData = data
          request.response = cachedResponse
          request.cachedDataHash = data.md5

          if expiryTimeFromNow > 0 {
            request.state = .ResponseAvailableFromCache
            request.cachedDataHash = data.md5

            if !request.alwaysLoad {
              request.state = .Completed
              return
            }
          } else {
            request.state = .StaleResponseAvailableFromCache
          }
        }
      }
    }

    let sessionToUse: NSURLSession = request.requiresAuthentication ? ephermeralSession: defaultSession

    request.task = sessionToUse.dataTaskWithRequest(urlRequest) {[unowned self]
      (data: NSData?, response: NSURLResponse?, error: NSError?) -> Void in

      request.responseData = data
      request.response = response as? NSHTTPURLResponse
      request.error = error

      if request.state == .Cancelled {
        return
      }

      if response == nil {
        request.state = .Error
        return
      }

      var statusCode: Int = 0
      if request.response != nil {
        statusCode = request.response!.statusCode
      }

      switch (statusCode) {
      case 304:
        request.responseData = nil

      case 400..<600:
        var userInfo = [String:AnyObject]()
        if let unwrappedResponse = response {
          userInfo["response"] = unwrappedResponse
        }
        if let unwrappedError = error {
          userInfo["error"] = unwrappedError
        }
        userInfo[NSLocalizedFailureReasonErrorKey] = "\(statusCode) " + NSHTTPURLResponse.localizedStringForStatusCode(statusCode)
        request.error = NSError(domain: "com.mknetworkkit.httperrordomain", code: statusCode, userInfo: userInfo)
        request.error = self.customizeError(request)

      default:
        break
      }

      if request.error == nil {
        if request.cacheble {
          self.dataCache?[request.equalityIdentifier] = request.responseData
          self.responseCache?[request.equalityIdentifier] = request.response
        }
        request.state = .Completed
      } else {
        request.state = .Error
      }
    }

    if request.requiresAuthentication {
      ephermeralSession.configuration.URLCredentialStorage?.setDefaultCredential(request.credential!
        , forProtectionSpace: request.protectionSpace!, task: request.task!)
    }

    request.task!.request = request
    request.state = .Started
  }

  //MARK: - Completion Handler for background tasks
  public func URLSession(session: NSURLSession, task: NSURLSessionTask, didCompleteWithError error: NSError?) {
    if session == backgroundSession {
      //let request = !
      task.request?.response = task.response as? NSHTTPURLResponse
      if task.request?.error == nil { // this could be set if the downloaded file can't be moved
        task.request?.error = error
      }

      if task.request?.state == .Cancelled {
        return
      }

      if task.response == nil {
        task.request?.state = .Error
        return
      }

      var statusCode: Int = 0
      if let response = task.request?.response {
        statusCode = response.statusCode
      }

      if statusCode >= 400 && statusCode < 600 {
        var userInfo = [String:AnyObject]()
        if let unwrappedResponse = task.response {
          userInfo["response"] = unwrappedResponse
        }
        if let unwrappedError = error {
          userInfo["error"] = unwrappedError
        }
        userInfo[NSLocalizedFailureReasonErrorKey] = "\(statusCode) " + NSHTTPURLResponse.localizedStringForStatusCode(statusCode)
        task.request?.error = NSError(domain: "com.mknetworkkit.httperrordomain", code: statusCode, userInfo: userInfo)
        task.request?.error = self.customizeError(task.request!)
      }

      if task.request?.error == nil {
        task.request?.state = .Completed
      } else {
        task.request?.state = .Error
      }
    }
  }

  //MARK: - Auth related
  public func URLSession(session: NSURLSession, task: NSURLSessionTask, didReceiveChallenge challenge: NSURLAuthenticationChallenge, completionHandler: (NSURLSessionAuthChallengeDisposition, NSURLCredential?) -> Void) {

    if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust {
      if let trust = challenge.protectionSpace.serverTrust {
        // TODO: - Add certificate pinning later here
        let credential = NSURLCredential(forTrust: trust)
        completionHandler(.UseCredential, credential)
      } else {
        completionHandler(.CancelAuthenticationChallenge, nil)
      }
    } else if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodClientCertificate {
      guard let certificate = task.request?.clientCertificate else {
        completionHandler(.CancelAuthenticationChallenge, nil)
        return
      }
      do {
        let certificateData = try NSData(contentsOfFile: certificate, options: .DataReadingMappedIfSafe)
        let password = task.request?.clientCertificatePassword
        let identityAndTrust:IdentityAndTrust = extractIdentity(certificateData, certPassword: password)
        let urlCredential:NSURLCredential = NSURLCredential(identity: identityAndTrust.identityRef,
          certificates: identityAndTrust.certArray as [AnyObject],
          persistence: .ForSession)
        completionHandler(.UseCredential, urlCredential)
      }
      catch let error as NSError {
        print (error)
        completionHandler(.CancelAuthenticationChallenge, nil)
      }
    } else if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodHTTPBasic ||
      challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodHTTPDigest ||
      challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodNTLM {
        if challenge.previousFailureCount == 3 {
          completionHandler(.RejectProtectionSpace, nil)
        } else {
          if let credential = session.configuration.URLCredentialStorage?.defaultCredentialForProtectionSpace(challenge.protectionSpace) {
            completionHandler(.UseCredential, credential)
          } else {
            completionHandler(.CancelAuthenticationChallenge, nil)
          }
        }
    } else if let authenticationHandler = authenticationHandler {
      authenticationHandler(session: session, task: task, challenge: challenge, completionHandler: completionHandler)
    } else {
      completionHandler(.CancelAuthenticationChallenge, nil)
    }
  }

  //MARK: - Progress markers
  public func URLSession(session: NSURLSession, task: NSURLSessionTask, didSendBodyData bytesSent: Int64, totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
    let progress = Double(totalBytesSent) / Double(totalBytesExpectedToSend)
    task.request?.progress = progress
  }

  public func URLSession(session: NSURLSession, downloadTask: NSURLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
    let progress = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
    downloadTask.request?.progress = progress
  }

  public func URLSession(session: NSURLSession, downloadTask: NSURLSessionDownloadTask, didFinishDownloadingToURL location: NSURL) {

    guard let path = downloadTask.request?.downloadPath else {
      print ("downloadPath not set in your Request. Unable to move downloaded file")
      return
    }
    do {
      try NSFileManager.defaultManager().moveItemAtPath(location.path!, toPath: path)
    } catch let error as NSError {
      downloadTask.request?.error = error
    }
  }

  public func URLSessionDidFinishEventsForBackgroundURLSession(session: NSURLSession) {
    if session != backgroundSession {
      return
    }
    backgroundSession.getTasksWithCompletionHandler {[unowned self] (dataTasks, uploadTasks, downloadTasks) -> Void in
      if dataTasks.count + uploadTasks.count + downloadTasks.count == 0 {
        self.backgroundSessionCompletionHandler?()
        self.backgroundSessionCompletionHandler = nil
      }
    }
  }

  struct IdentityAndTrust {
    var identityRef:SecIdentityRef
    var trust:SecTrustRef
    var certArray:NSArray
  }

  func extractIdentity(certData: NSData, certPassword: String?) -> IdentityAndTrust {

    var identityAndTrust: IdentityAndTrust!
    var securityError: OSStatus = errSecSuccess

    var items: CFArray?

    var certOptions = [:]
    if let password = certPassword {
      certOptions = [kSecImportExportPassphrase as String: password]
    }
    securityError = SecPKCS12Import(certData, certOptions, &items)

    if securityError == errSecSuccess {

      let certItems:CFArray = items as CFArray!
      let certItemsArray:Array = certItems as Array
      let dict:AnyObject? = certItemsArray.first

      if let certEntry:Dictionary = dict as? Dictionary<String, AnyObject> {

        // grab the identity
        let identityPointer:AnyObject? = certEntry["identity"]
        let secIdentityRef:SecIdentityRef = identityPointer as! SecIdentityRef!

        // grab the trust
        let trustPointer:AnyObject? = certEntry["trust"]
        let trustRef:SecTrustRef = trustPointer as! SecTrustRef

        // grab the certificate chain
        var certRef: SecCertificate?
        SecIdentityCopyCertificate(secIdentityRef, &certRef)
        let certArray = NSMutableArray()
        certArray.addObject(certRef as SecCertificateRef!)
        
        identityAndTrust = IdentityAndTrust(identityRef: secIdentityRef, trust: trustRef, certArray: certArray)
      }
    }
    return identityAndTrust
  }
}