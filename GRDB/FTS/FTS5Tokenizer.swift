#if SQLITE_ENABLE_FTS5
    /// A low-level SQLite function that lets FTS5Tokenizer notify tokens.
    ///
    /// See FTS5Tokenizer.tokenize(context:flags:pText:nText:tokenCallback:)
    public typealias FTS5TokenCallback = @convention(c) (_ context: UnsafeMutableRawPointer?, _ flags: Int32, _ pToken: UnsafePointer<Int8>?, _ nToken: Int32, _ iStart: Int32, _ iEnd: Int32) -> Int32
    
    /// Flags that indicate the reason why FTS5 is requesting tokenization.
    ///
    /// See https://www.sqlite.org/fts5.html#custom_tokenizers
    public struct FTS5TokenizationFlags : OptionSet {
        public let rawValue: Int32
        
        public init(rawValue: Int32) {
            self.rawValue = rawValue
        }
        
        /// FTS5_TOKENIZE_QUERY
        public static let query = FTS5TokenizationFlags(rawValue: FTS5_TOKENIZE_QUERY)
        
        /// FTS5_TOKENIZE_PREFIX
        public static let prefix = FTS5TokenizationFlags(rawValue: FTS5_TOKENIZE_PREFIX)
        
        /// FTS5_TOKENIZE_DOCUMENT
        public static let document = FTS5TokenizationFlags(rawValue: FTS5_TOKENIZE_DOCUMENT)
        
        /// FTS5_TOKENIZE_AUX
        public static let aux = FTS5TokenizationFlags(rawValue: FTS5_TOKENIZE_AUX)
    }
    
    /// The protocol for FTS5 tokenizers
    public protocol FTS5Tokenizer : class {
        /// Tokenizes the text described by `pText` and `nText`, and
        /// notifies found tokens to the `tokenCallback` function.
        ///
        /// It matches the `xTokenize` function documented at https://www.sqlite.org/fts5.html#custom_tokenizers
        ///
        /// - parameters:
        ///     - context: An opaque pointer that is the first argument to
        ///       the `tokenCallback` function
        ///     - flags: Flags that indicate the reason why FTS5 is
        ///       requesting tokenization.
        ///     - pText: The tokenized text bytes. May or may not be
        ///       nul-terminated.
        ///     - nText: The number of bytes in the tokenized text.
        ///     - tokenCallback: The function to call for each found token.
        ///       It matches the `xToken` callback at https://www.sqlite.org/fts5.html#custom_tokenizers
        func tokenize(context: UnsafeMutableRawPointer?, flags: FTS5TokenizationFlags, pText: UnsafePointer<Int8>?, nText: Int32, tokenCallback: FTS5TokenCallback?) -> Int32
    }
    
    extension FTS5Tokenizer {
        
        /// Returns an array of tokens found in the string argument.
        ///
        ///     let tokenizer = try db.makeTokenizer(.ascii())
        ///     try tokenizer.tokenize("foo bar", flags: .document) // ["foo", "bar"]
        ///
        /// - parameter string: The string to tokenize
        /// - parameter flags: Tokenization flags
        ///     - .document: Tokenize like a document being inserted into an FTS table.
        ///     - .query: Tokenize like the search pattern of the MATCH operator.
        /// - parameter tokenizer: A FTS5TokenizerDescriptor such as .ascii()
        public func tokenize(_ string: String, flags: FTS5TokenizationFlags) throws -> [String] {
            return try ContiguousArray(string.utf8).withUnsafeBufferPointer { buffer -> [String] in
                guard let addr = buffer.baseAddress else {
                    return []
                }
                let pText = UnsafeMutableRawPointer(mutating: addr).assumingMemoryBound(to: Int8.self)
                let nText = Int32(buffer.count)
                
                var context = TokenizeContext()
                try withUnsafeMutablePointer(to: &context) { contextPointer in
                    let code = tokenize(context: UnsafeMutableRawPointer(contextPointer), flags: flags, pText: pText, nText: nText, tokenCallback: { (contextPointer, flags, pToken, nToken, iStart, iEnd) -> Int32 in
                        guard let contextPointer = contextPointer else { return SQLITE_ERROR }
                        
                        // Extract token
                        guard let token = pToken.flatMap({ String(data: Data(bytesNoCopy: UnsafeMutableRawPointer(mutating: $0), count: Int(nToken), deallocator: .none), encoding: .utf8) }) else {
                            return SQLITE_OK
                        }
                        
                        contextPointer.assumingMemoryBound(to: TokenizeContext.self).pointee.tokens.append(token)
                        return SQLITE_OK
                    })
                    if (code != SQLITE_OK) {
                        throw DatabaseError(code: code)
                    }
                }
                return context.tokens
            }
        }
    }
    
    private class TokenizeContext {
        var tokens: [String] = []
    }
    
    extension Database {
        /// MARK: - FTS5 Tokenizers
        
        /// Private type that makes a pre-registered FTS5 tokenizer available
        /// through the FTS5Tokenizer protocol.
        private final class FTS5RegisteredTokenizer : FTS5Tokenizer {
            let xTokenizer: fts5_tokenizer
            let tokenizerPointer: OpaquePointer
            
            init(xTokenizer: fts5_tokenizer, contextPointer: UnsafeMutableRawPointer?, arguments: [String]) throws {
                guard let xCreate = xTokenizer.xCreate else {
                    throw DatabaseError(code: SQLITE_ERROR, message: "nil fts5_tokenizer.xCreate")
                }
                
                self.xTokenizer = xTokenizer
                
                var tokenizerPointer: OpaquePointer? = nil
                let code: Int32
                if let argument = arguments.first {
                    // turn [String] into ContiguousArray<UnsafePointer<Int8>>
                    func convertArguments<Result>(_ array: inout ContiguousArray<UnsafePointer<Int8>>, _ car: String, _ cdr: [String], _ body: (ContiguousArray<UnsafePointer<Int8>>) -> Result) -> Result {
                        return car.withCString { cString in
                            if let car = cdr.first {
                                array.append(cString)
                                return convertArguments(&array, car, Array(cdr.suffix(from: 1)), body)
                            } else {
                                return body(array)
                            }
                        }
                    }
                    var cStrings = ContiguousArray<UnsafePointer<Int8>>()
                    code = convertArguments(&cStrings, argument, Array(arguments.suffix(from: 1))) { cStrings in
                        cStrings.withUnsafeBufferPointer { azArg in
                            xCreate(contextPointer, UnsafeMutablePointer(OpaquePointer(azArg.baseAddress!)), Int32(cStrings.count), &tokenizerPointer)
                        }
                    }
                } else {
                    code = xCreate(contextPointer, nil, 0, &tokenizerPointer)
                }
                
                guard code == SQLITE_OK else {
                    throw DatabaseError(code: code, message: "failed fts5_tokenizer.xCreate")
                }
                
                if let tokenizerPointer = tokenizerPointer {
                    self.tokenizerPointer = tokenizerPointer
                } else {
                    throw DatabaseError(code: code, message: "nil tokenizer")
                }
            }
            
            deinit {
                if let delete = xTokenizer.xDelete {
                    delete(tokenizerPointer)
                }
            }
            
            func tokenize(context: UnsafeMutableRawPointer?, flags: FTS5TokenizationFlags, pText: UnsafePointer<Int8>?, nText: Int32, tokenCallback: FTS5TokenCallback?) -> Int32 {
                guard let xTokenize = xTokenizer.xTokenize else {
                    return SQLITE_ERROR
                }
                return xTokenize(tokenizerPointer, context, flags.rawValue, pText, nText, tokenCallback)
            }
        }
        
        /// Creates an FTS5 tokenizer, given its descriptor.
        ///
        ///     let unicode61 = try db.makeTokenizer(.unicode61())
        ///
        /// It is a programmer error to use the tokenizer outside of a protected
        /// database queue, or after the database has been closed.
        ///
        /// Use this method when you implement a custom wrapper tokenizer:
        ///
        ///     final class MyTokenizer : FTS5WrapperTokenizer {
        ///         var wrappedTokenizer: FTS5Tokenizer
        ///
        ///         init(db: Database, arguments: [String]) throws {
        ///             wrappedTokenizer = try db.makeTokenizer(.unicode61())
        ///         }
        ///     }
        public func makeTokenizer(_ descriptor: FTS5TokenizerDescriptor) throws -> FTS5Tokenizer {
            guard let api = FTS5.api(self) else {
                throw DatabaseError(code: SQLITE_MISUSE, message: "FTS5 API not found")
            }
            
            let xTokenizerPointer: UnsafeMutablePointer<fts5_tokenizer> = .allocate(capacity: 1)
            defer { xTokenizerPointer.deallocate(capacity: 1) }
            
            let contextHandle: UnsafeMutablePointer<UnsafeMutableRawPointer?> = .allocate(capacity: 1)
            defer { contextHandle.deallocate(capacity: 1) }
            
            let code = api.pointee.xFindTokenizer!(
                UnsafeMutablePointer(mutating: api),
                descriptor.name,
                contextHandle,
                xTokenizerPointer)
            
            guard code == SQLITE_OK else {
                throw DatabaseError(code: code)
            }
            
            let contextPointer = contextHandle.pointee
            return try FTS5RegisteredTokenizer(xTokenizer: xTokenizerPointer.pointee, contextPointer: contextPointer, arguments: descriptor.arguments)
        }
    }
#endif