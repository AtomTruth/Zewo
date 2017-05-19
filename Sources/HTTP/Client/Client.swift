import Core
import IO
import Venice
import struct Foundation.URL

public enum ClientError : Error {
    case invalidURL
    case hostRequired
    case invalidScheme
}

public final class Client {
    fileprivate struct Connection {
        let stream: DuplexStream
        let serializer: RequestSerializer
        let parser: ResponseParser
    }
    
    public struct Configuration {
        /// Pool size
        public var poolSize: ClosedRange<Int> = 5 ... 10
        
        /// Parser buffer size
        public var parserBufferSize: Int = 4096
        
        /// Serializer buffer size
        public var serializerBufferSize: Int = 4096
        
        /// Address resolution timeout
        public var addressResolutionTimeout: Duration = 1.minute
        
        /// Connection timeout
        public var connectionTimeout: Duration = 1.minute
        
        /// Borrow timeout
        public var borrowTimeout: Duration = 5.minutes
        
        /// Parse timeout
        public var parseTimeout: Duration = 5.minutes
        
        /// Serialization timeout
        public var serializeTimeout: Duration = 5.minutes
        
        /// Close connection timeout
        public var closeConnectionTimeout: Duration = 1.minute
        
        public init() {}
        
        public static var `default`: Configuration {
            return Configuration()
        }
    }
    
    /// Client configuration.
    public let configuration: Configuration
    
    private let host: String
    private let port: Int
    private let logger: Logger
    private let pool: Pool
    
    /// Creates a new HTTP client
    public init(
        url: URL,
        logger: Logger = defaultLogger,
        configuration: Configuration = .default
    ) throws {
        var secure = true
        
        if let scheme = url.scheme {
            switch scheme {
            case "https":
                secure = true
            case "http":
                secure = false
            default:
                throw ClientError.invalidScheme
            }
        }
        
        guard let host = url.host else {
            throw ClientError.hostRequired
        }
        
        let port = url.port ?? (secure ? 443 : 80)
        
        self.host = host
        self.port = port
        self.logger = logger
        self.configuration = configuration
        
        self.pool = try Pool(size: configuration.poolSize) {
            let stream: DuplexStream
            
            if secure {
                stream = try TLSStream(
                    host: host,
                    port: port,
                    deadline: configuration.addressResolutionTimeout.fromNow()
                )
            } else {
                stream = try TCPStream(
                    host: host,
                    port: port,
                    deadline: configuration.addressResolutionTimeout.fromNow()
                )
            }
            
            try stream.open(deadline: configuration.connectionTimeout.fromNow())
            
            let serializer = RequestSerializer(
                stream: stream,
                bufferSize: configuration.serializerBufferSize
            )
            
            let parser = ResponseParser(
                stream: stream,
                bufferSize: configuration.parserBufferSize
            )
            
            return Connection(
                stream: stream,
                serializer: serializer,
                parser: parser
            )
        }
    }
    
    /// Creates a new HTTP client
    public convenience init(
        url: String,
        logger: Logger = defaultLogger,
        configuration: Configuration = .default
    ) throws {
        guard let url = URL(string: url) else {
            throw ClientError.invalidURL
        }
        
        try self.init(url: url, logger: logger, configuration: configuration)
    }
    
    private static var defaultLogger: Logger {
        return Logger(name: "HTTP client")
    }
    
    func send(_ request: Request) throws -> Response {
        loop: while true {
            let connection = try pool.borrow(deadline: configuration.borrowTimeout.fromNow())
            
            let stream = connection.stream
            let parser = connection.parser
            let serializer = connection.serializer
            
            request.host = host + ":" + port.description
            request.userAgent = "Zewo"
            
            do {
                try serializer.serialize(
                    request,
                    deadline: configuration.serializeTimeout.fromNow()
                )
                
                let response = try parser.parse(
                    deadline: configuration.parseTimeout.fromNow()
                )
                
                if let upgrade = request.upgradeConnection {
                    try upgrade(response, stream)
                    try stream.done(deadline: configuration.closeConnectionTimeout.fromNow())
                    pool.dispose(connection)
                } else {
                    pool.return(connection)
                }
                
                return response
            } catch {
                pool.dispose(connection)
                continue loop
            }
        }
    }
}

fileprivate class Pool {
    fileprivate var size: ClosedRange<Int>
    fileprivate var borrowed = 0
    fileprivate var available: [Client.Connection] = []
    fileprivate var waitList: Channel<Void>
    fileprivate var waiting: Int = 0
    
    fileprivate let create: (Void) throws -> Client.Connection
    
    fileprivate init(
        size: ClosedRange<Int>,
        _ create: @escaping (Void) throws -> Client.Connection
    ) throws {
        self.size = size
        self.create = create
        
        waitList = try Channel()
        
        for _ in 0 ..< size.lowerBound {
            let connection = try create()
            self.available.append(connection)
        }
    }
    
    fileprivate func `return`(_ stream: Client.Connection) {
        available.append(stream)
        
        borrowed -= 1
        
        if waiting > 0 {
            try? waitList.send((), deadline: .immediately)
        }
    }
    
    fileprivate func dispose(_ stream: Client.Connection) {
        borrowed -= 1
    }
    
    fileprivate func borrow(deadline: Deadline) throws -> Client.Connection {
        var waitCount = 0
        
        while true {
            if let stream = available.popLast() {
                borrowed += 1
                return stream
            }
            
            if borrowed + available.count < size.upperBound {
                let stream = try create()
                borrowed += 1
                return stream
            }
            
            waitCount += 1
            
            defer {
                waiting -= waitCount
            }
            
            try waitList.receive(deadline: deadline)
        }
    }
}
