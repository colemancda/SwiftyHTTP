//
//  HTTPParser.swift
//  SwiftyHTTP
//
//  Created by Helge Heß on 6/18/14.
//  Copyright (c) 2014 Helge Hess. All rights reserved.
//

enum HTTPParserType {
  case Request, Response, Both
}

class HTTPParser {
  
  enum ParseState {
    case Idle, URL, HeaderName, HeaderValue, Body
  }
  
  let parser     : COpaquePointer = nil
  let buffer     = RawByteBuffer(capacity: 4096)
  var parseState = ParseState.Idle
  
  var isWiredUp  = false
  var url        : String?
  var lastName   : String?
  var headers    = Dictionary<String, String>(minimumCapacity: 32)
  var body       : [UInt8]?
  
  var message    : HTTPMessage?
  
  
  init(type: HTTPParserType = .Both) {
    var cType: http_parser_type
    switch type {
      case .Request:  cType = HTTP_REQUEST
      case .Response: cType = HTTP_RESPONSE
      case .Both:     cType = HTTP_BOTH
    }
    parser = http_parser_init(cType)
  }
  deinit {
    http_parser_free(parser)
  }
  
  
  /* callbacks */
  
  func onRequest(cb: ((HTTPRequest) -> Void)?) -> Self {
    requestCB = cb
    return self
  }
  func onResponse(cb: ((HTTPResponse) -> Void)?) -> Self {
    responseCB = cb
    return self
  }
  func onHeaders(cb: ((HTTPMessage) -> Bool)?) -> Self {
    headersCB = cb
    return self
  }
  func onBodyData(cb: ((HTTPMessage, CString, UInt) -> Bool)?) -> Self {
    bodyDataCB = cb
    return self
  }
  func resetEventHandlers() {
    requestCB  = nil
    responseCB = nil
    headersCB  = nil
    bodyDataCB = nil
  }
  var requestCB  : ((HTTPRequest)  -> Void)?
  var responseCB : ((HTTPResponse) -> Void)?
  var headersCB  : ((HTTPMessage)  -> Bool)?
  var bodyDataCB : ((HTTPMessage, CString, UInt) -> Bool)?
  
  
  /* write */
  
  var bodyIsFinal: Bool { return http_body_is_final(parser) == 0 ? false:true }
  
  func write(buffer: CString, _ count: Int) -> HTTPParserError {
    let len = UInt(count)
    
    if !isWiredUp {
      wireUpCallbacks()
    }
    
    let bytesConsumed = http_parser_execute(self.parser, buffer, len)
    
    let errno = http_parser_get_errno(parser)
    let err   = HTTPParserError.fromRaw(Int(errno.value))!
    
    if err != .OK {
      // Now hitting this, not quite sure why. Maybe a Safari feature?
      let s = http_errno_name(errno)
      let d = http_errno_description(errno)
      println("BYTES \(bytesConsumed) ERRNO: \(err) \(s) \(d)")
    }
    return err
  }
  
  func write(buffer: [CChar], _ count: Int) -> HTTPParserError {
    if count == 0 {
      return self.write("", 0)
    }
    return CString.withCString(buffer) { self.write($0, count) }
  }
  
  
  /* pending data handling */
  
  func clearState() {
    self.url      = nil
    self.lastName = nil
    self.body     = nil
    self.headers.removeAll(keepCapacity: true)
  }
  
  func addData(data: CString, length: UInt) -> Int32 {
    if parseState == .Body && bodyDataCB && message {
      return bodyDataCB!(message!, data, length) ? 42 : 0
    }
    else {
      buffer.add(data, length: length)
    }
    return 0
  }
  
  func processDataForState(state: ParseState, d: CString, l: UInt) -> Int32 {
    if (state == parseState) { // more data for same field
      return addData(d, length: l)
    }
    
    switch parseState {
      case .HeaderValue:
        // finished parsing a header
        assert(lastName)
        if let n = lastName {
          headers[n] = buffer.asString()
        }
        buffer.reset()
        lastName = nil
      
      case .HeaderName:
        assert(lastName == nil)
        lastName = buffer.asString()
        buffer.reset()
      
      case .URL:
        assert(url == nil)
        url = buffer.asString()
        buffer.reset()
      
      case .Body:
        if !bodyDataCB {
          body = buffer.asByteArray()
        }
        buffer.reset()
      
      default: // needs some block, no empty default possible
        break
    }
    
    /* start a new state */
    
    parseState = state
    buffer.reset()
    return addData(d, length: l)
  }
  
  var isRequest  : Bool { return http_parser_get_type(parser) == 0 }
  var isResponse : Bool { return http_parser_get_type(parser) == 1 }
  
  class func parserCodeToMethod(rq: CUnsignedInt) -> HTTPMethod? {
    var method : HTTPMethod?
    switch rq { // hardcode C enum value, defines from http_parser n/a
      case  0: method = HTTPMethod.DELETE
      case  1: method = HTTPMethod.GET
      case  2: method = HTTPMethod.HEAD
      case  3: method = HTTPMethod.POST
      case  4: method = HTTPMethod.PUT
      case  5: method = HTTPMethod.CONNECT
      case  6: method = HTTPMethod.OPTIONS
      case  7: method = HTTPMethod.TRACE
      case  8: method = HTTPMethod.COPY
      case  9: method = HTTPMethod.LOCK
      case 10: method = HTTPMethod.MKCOL
      case 11: method = HTTPMethod.MOVE
      case 12: method = HTTPMethod.PROPFIND
      case 13: method = HTTPMethod.PROPPATCH
      case 14: method = HTTPMethod.SEARCH
      case 15: method = HTTPMethod.UNLOCK
        
      case 16: method = HTTPMethod.REPORT((nil, nil)) // FIXME: peek body ..
        
      case 17: method = HTTPMethod.MKACTIVITY
      case 18: method = HTTPMethod.CHECKOUT
      case 19: method = HTTPMethod.MERGE
        
      case 20: method = HTTPMethod.MSEARCH
      case 21: method = HTTPMethod.NOTIFY
      case 22: method = HTTPMethod.SUBSCRIBE
      case 23: method = HTTPMethod.UNSUBSCRIBE
        
      case 24: method = HTTPMethod.PATCH
      case 25: method = HTTPMethod.PURGE
      
      case 26: method = HTTPMethod.MKCALENDAR
      
      default:
        // Note: extra custom methods don't work (I think)
        method = nil
    }
    return method
  }
  
  func headerFinished() -> Int32 {
    self.processDataForState(.Body, d: "", l: 0)
    
    message = nil
    
    var major : CUnsignedShort = 1
    var minor : CUnsignedShort = 1
    
    if isRequest {
      var rq : CUnsignedInt = 0
      http_parser_get_request_info(parser, &major, &minor, &rq)
      
      var method  = HTTPParser.parserCodeToMethod(rq)
      
      message = HTTPRequest(method: method!, url: url!,
                            version: ( Int(major), Int(minor) ),
                            headers: headers)
      self.clearState()
    }
    else if isResponse {
      var status : CUnsignedInt = 200
      http_parser_get_response_info(parser, &major, &minor, &status)
      
      // TBD: also grab status text? Doesn't matter in the real world ...
      message = HTTPResponse(status: HTTPStatus(Int(status)),
                             version: ( Int(major), Int(minor) ),
                             headers: headers)
      self.clearState()
    }
    else { // FIXME: PS style great error handling
      let msgtype = http_parser_get_type(parser)
      println("Unexpected message? \(msgtype)")
      assert(msgtype == 0 || msgtype == 1)
    }
    
    if let m = message {
      if  let cb = headersCB {
        return cb(m) ? 0 : 42
      }
    }
    
    return 0
  }
  
  func messageFinished() -> Int32 {
    self.processDataForState(.Idle, d: "", l: 0)
    
    if let m = message {
      m.bodyAsByteArray = body
      
      if let rq = m as? HTTPRequest {
        if let cb = requestCB {
          cb(rq)
        }
      }
      else if let res = m as? HTTPResponse {
        if let cb = responseCB {
          cb(res)
        }
      }
      else {
        assert(false, "Expected Request or Response object")
      }
      
      return 0
    }
    else {
      println("did not parse a message ...")
      return 42
    }
  }
  
  /* callbacks */
  
  func wireUpCallbacks() {
    // http_cb      => (p: COpaquePointer) -> Int32
    // http_data_cb => (p: COpaquePointer, d: CString, l: UInt)
    // Note: CString is NOT a real C string, it's length terminated
    http_parser_set_on_message_begin(parser, {
      [unowned self] (_: COpaquePointer) -> Int32 in
      self.message  = nil
      self.clearState()
      return 0
    })
    http_parser_set_on_message_complete(parser, {
      [unowned self] (_: COpaquePointer) -> Int32 in
      self.messageFinished()
     })
    http_parser_set_on_headers_complete(parser) {
      [unowned self] (_: COpaquePointer) -> Int32 in
      self.headerFinished()
    }
    http_parser_set_on_url(parser) { [unowned self] in
      self.processDataForState(.URL, d: $1, l: $2)
    }
    http_parser_set_on_header_field(parser) { [unowned self] in
      self.processDataForState(.HeaderName, d: $1, l: $2)
    }
    http_parser_set_on_header_value(parser) { [unowned self] in
      self.processDataForState(.HeaderValue, d: $1, l: $2)
    }
    http_parser_set_on_body(parser) { [unowned self] in
      self.processDataForState(.Body, d: $1, l: $2)
    }
  }
}

extension HTTPParser : Printable {
  
  var description : String {
    return "<HTTPParser \(parseState) @\(buffer.count)>"
  }
}

enum HTTPParserError : Int, Printable {
  // manual mapping, Swift can't bridge the http_parser macros
  case OK
  case cbMessageBegin, cbURL, cbBody, cbMessageComplete, cbStatus
  case cbHeaderField, cbHeaderValue, cbHeadersComplete
  case InvalidEOFState, HeaderOverflow, ClosedConnection
  case InvalidVersion, InvalidStatus, InvalidMethod, InvalidURL
  case InvalidHost, InvalidPort, InvalidPath, InvalidQueryString
  case InvalidFragment
  case LineFeedExpected
  case InvalidHeaderToken, InvalidContentLength, InvalidChunkSize
  case InvalidConstant, InvalidInternalState
  case NotStrict, Paused
  case Unknown
  
  var description : String { return errorDescription }
  
  var errorDescription : String {
    switch self {
      case OK:                   return "Success"
      case cbMessageBegin:       return "The on_message_begin callback failed"
      case cbURL:                return "The on_url callback failed"
      case cbBody:               return "The on_body callback failed"
      case cbMessageComplete:
        return "The on_message_complete callback failed"
      case cbStatus:             return "The on_status callback failed"
      case cbHeaderField:        return "The on_header_field callback failed"
      case cbHeaderValue:        return "The on_header_value callback failed"
      case cbHeadersComplete:
        return "The on_headers_complete callback failed"
      
      case InvalidEOFState:      return "Stream ended at an unexpected time"
      case HeaderOverflow:
        return "Too many header bytes seen; overflow detected"
      case ClosedConnection:
        return "Data received after completed connection: close message"
      case InvalidVersion:       return "Invalid HTTP version"
      case InvalidStatus:        return "Invalid HTTP status code"
      case InvalidMethod:        return "Invalid HTTP method"
      case InvalidURL:           return "Invalid URL"
      case InvalidHost:          return "Invalid host"
      case InvalidPort:          return "Invalid port"
      case InvalidPath:          return "Invalid path"
      case InvalidQueryString:   return "Invalid query string"
      case InvalidFragment:      return "Invalid fragment"
      case LineFeedExpected:     return "LF character expected"
      case InvalidHeaderToken:   return "Invalid character in header"
      case InvalidContentLength:
        return "Invalid character in content-length header"
      case InvalidChunkSize:     return "Invalid character in chunk size header"
      case InvalidConstant:      return "Invalid constant string"
      case InvalidInternalState: return "Encountered unexpected internal state"
      case NotStrict:            return "Strict mode assertion failed"
      case Paused:               return "Parser is paused"
      default:                   return "Unknown Error"
    }
  }
}