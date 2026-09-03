import Foundation
import zlib
import CommonCrypto

/// 批量上报：POST {endpoint}/v1/track/batch
/// - body gzip 压缩（zlib deflateInit2 windowBits=15+16）；压缩失败降级不压缩且不带 Content-Encoding
/// - X-Sign = HMAC-SHA256(最终传输字节, appSecret) 的 hex
final class Uploader {
    static let sdkVersion = "1.0.0"

    struct Config {
        let appKey: String
        let appSecret: String
        /// 已拼好 /v1/track/batch 的完整 URL
        let url: URL
    }

    enum Result {
        case success
        /// 400/401：丢弃该批，重试无意义
        case discard(httpCode: Int)
        /// 429/5xx/网络异常：退避重试
        case retryable
    }

    struct BatchPayload: Codable {
        let app_key: String
        let sent_time: Int64
        let sdk_version: String
        let events: [AnalyticsEvent]
    }

    private let config: Config
    private let session: URLSession
    private let encoder = JSONEncoder()

    init(config: Config) {
        self.config = config
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 60
        session = URLSession(configuration: configuration)
    }

    func upload(_ events: [AnalyticsEvent], completion: @escaping (Result) -> Void) {
        let payload = BatchPayload(
            app_key: config.appKey,
            sent_time: Int64(Date().timeIntervalSince1970 * 1000),
            sdk_version: Uploader.sdkVersion,
            events: events
        )
        guard let jsonBody = try? encoder.encode(payload) else {
            completion(.discard(httpCode: 0))
            return
        }

        let body: Data
        var headers: [String: String] = [
            "Content-Type": "application/json",
            "X-App-Key": config.appKey,
            "X-Timestamp": String(Int64(Date().timeIntervalSince1970 * 1000))
        ]
        if let compressed = Uploader.gzip(jsonBody) {
            body = compressed
            headers["Content-Encoding"] = "gzip"
        } else {
            // 压缩失败降级：不压缩、不带 Content-Encoding
            body = jsonBody
        }
        // X-Sign 对最终传输字节计算
        headers["X-Sign"] = Uploader.hmacSHA256Hex(data: body, key: config.appSecret)

        var request = URLRequest(url: config.url)
        request.httpMethod = "POST"
        request.httpBody = body
        headers.forEach { request.setValue($1, forHTTPHeaderField: $0) }

        session.dataTask(with: request) { _, response, error in
            if error != nil {
                completion(.retryable)
                return
            }
            guard let http = response as? HTTPURLResponse else {
                completion(.retryable)
                return
            }
            switch http.statusCode {
            case 200..<300:
                completion(.success)
            case 400, 401:
                completion(.discard(httpCode: http.statusCode))
            default:
                // 429 / 5xx / 其他：退避重试
                completion(.retryable)
            }
        }.resume()
    }

    // MARK: gzip（zlib，windowBits = 15 + 16 输出 gzip 格式）

    static func gzip(_ data: Data) -> Data? {
        guard !data.isEmpty else { return nil }
        var stream = z_stream()
        var status = deflateInit2_(&stream, Z_DEFAULT_COMPRESSION, Z_DEFLATED,
                                   MAX_WBITS + 16, 8, Z_DEFAULT_STRATEGY,
                                   ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size))
        guard status == Z_OK else { return nil }
        defer { deflateEnd(&stream) }

        let chunkSize = 16 * 1024
        var output = Data()
        output.reserveCapacity(data.count / 2)
        let buffer = UnsafeMutablePointer<Bytef>.allocate(capacity: chunkSize)
        defer { buffer.deallocate() }

        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.baseAddress else {
                status = Z_BUF_ERROR
                return
            }
            stream.next_in = UnsafeMutablePointer<Bytef>(mutating: base.assumingMemoryBound(to: Bytef.self))
            stream.avail_in = uInt(data.count)
            repeat {
                stream.next_out = buffer
                stream.avail_out = uInt(chunkSize)
                status = deflate(&stream, Z_FINISH)
                let produced = chunkSize - Int(stream.avail_out)
                if produced > 0 {
                    output.append(buffer, count: produced)
                }
            } while status == Z_OK
        }
        return status == Z_STREAM_END ? output : nil
    }

    // MARK: HMAC-SHA256 hex

    static func hmacSHA256Hex(data: Data, key: String) -> String {
        var digest = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        let keyBytes = Array(key.utf8)
        data.withUnsafeBytes { dataPtr in
            keyBytes.withUnsafeBytes { keyPtr in
                CCHmac(CCHmacAlgorithm(kCCHmacAlgSHA256),
                       keyPtr.baseAddress, keyBytes.count,
                       dataPtr.baseAddress, data.count,
                       &digest)
            }
        }
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
