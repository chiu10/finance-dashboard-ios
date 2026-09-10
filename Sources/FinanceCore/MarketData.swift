import Foundation

public enum QuoteProviderError: Error, Equatable, Sendable {
    case unsupportedAsset
    case invalidResponse
    case unavailable
}

public protocol QuoteProvider: Sendable {
    var identifier: String { get }
    func latestQuote(for asset: InvestmentAsset) async throws -> PriceQuote
}

public protocol ExchangeRateProvider: Sendable {
    func rate(from: String, to: String) async throws -> Decimal
}

/// Public, unauthenticated reference rates. The caller must retain the last good rate on failure.
public struct FrankfurterExchangeRateProvider: ExchangeRateProvider {
    private let session: URLSession
    public init(session: URLSession = .shared) { self.session = session }
    public func rate(from: String, to: String) async throws -> Decimal {
        guard from != to,
              let url = URL(string: "https://api.frankfurter.app/latest?from=\(from)&to=\(to)") else { return 1 }
        var request = URLRequest(url: url); request.timeoutInterval = 8
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { throw QuoteProviderError.unavailable }
        let payload = try JSONDecoder().decode(Payload.self, from: data)
        guard let value = payload.rates[to], value > 0 else { throw QuoteProviderError.invalidResponse }
        return value
    }
    private struct Payload: Decodable { let rates: [String: Decimal] }
}

public struct BinancePublicQuoteProvider: QuoteProvider {
    public let identifier = "binance-public"
    private let session: URLSession
    private let timeout: TimeInterval
    private let retries: Int

    public init(session: URLSession = .shared, timeout: TimeInterval = 8, retries: Int = 1) {
        self.session = session
        self.timeout = timeout
        self.retries = max(0, retries)
    }

    public func latestQuote(for asset: InvestmentAsset) async throws -> PriceQuote {
        guard asset.market == .crypto else { throw QuoteProviderError.unsupportedAsset }
        let symbol = asset.symbol.uppercased().hasSuffix("USDT") ? asset.symbol.uppercased() : "\(asset.symbol.uppercased())USDT"
        guard symbol.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) }) else { throw QuoteProviderError.invalidResponse }
        var components = URLComponents(string: "https://api.binance.com/api/v3/ticker/price")
        components?.queryItems = [URLQueryItem(name: "symbol", value: symbol)]
        guard let url = components?.url else { throw QuoteProviderError.invalidResponse }
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        var lastError: Error = QuoteProviderError.unavailable
        for _ in 0 ... retries {
            do {
                let (data, response) = try await session.data(for: request)
                guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { throw QuoteProviderError.unavailable }
                let payload = try JSONDecoder().decode(BinancePrice.self, from: data)
                guard let decimal = Decimal(string: payload.price, locale: Locale(identifier: "en_US_POSIX")), decimal > 0 else { throw QuoteProviderError.invalidResponse }
                return PriceQuote(assetID: asset.id, price: decimal, currencyCode: "USD", source: identifier)
            } catch {
                lastError = error
            }
        }
        throw lastError
    }

    private struct BinancePrice: Decodable { let price: String }
}

public struct YahooFinanceQuoteProvider: QuoteProvider {
    public let identifier = "yahoo-finance-public"
    private let session: URLSession
    private let timeout: TimeInterval
    private let retries: Int
    public init(session: URLSession = .shared, timeout: TimeInterval = 8, retries: Int = 1) { self.session = session; self.timeout = timeout; self.retries = max(0, retries) }
    public func latestQuote(for asset: InvestmentAsset) async throws -> PriceQuote {
        guard asset.market == .taiwan || asset.market == .unitedStates else { throw QuoteProviderError.unsupportedAsset }
        let suffix = asset.market == .taiwan ? ".TW" : ""
        guard let url = URL(string: "https://query1.finance.yahoo.com/v8/finance/chart/\(asset.symbol.uppercased())\(suffix)?range=1d&interval=1d") else { throw QuoteProviderError.invalidResponse }
        var request = URLRequest(url: url); request.timeoutInterval = timeout
        var lastError: Error = QuoteProviderError.unavailable
        for _ in 0 ... retries {
            do {
                let (data, response) = try await session.data(for: request)
                guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { throw QuoteProviderError.unavailable }
                let payload = try JSONDecoder().decode(YahooChartResponse.self, from: data)
                guard let price = payload.chart.result?.first?.meta.regularMarketPrice, price > 0 else { throw QuoteProviderError.invalidResponse }
                return PriceQuote(assetID: asset.id, price: price, currencyCode: asset.currencyCode, source: identifier)
            } catch { lastError = error }
        }
        throw lastError
    }

    private struct YahooChartResponse: Decodable {
        struct Chart: Decodable { struct Result: Decodable { struct Meta: Decodable { let regularMarketPrice: Decimal? }; let meta: Meta }; let result: [Result]? }
        let chart: Chart
    }
}

@available(*, deprecated, message: "Use YahooFinanceQuoteProvider")
public typealias UnavailableStockQuoteProvider = YahooFinanceQuoteProvider

public enum QuoteRefreshResult: Equatable, Sendable {
    case updated(PriceQuote)
    case retainedStale(PriceQuote?)
}

public enum QuoteRefreshService {
    public static func refresh(
        asset: InvestmentAsset,
        provider: any QuoteProvider,
        existingQuote: PriceQuote?
    ) async -> QuoteRefreshResult {
        do {
            var quote = try await provider.latestQuote(for: asset)
            quote.isStale = false
            return .updated(quote)
        } catch {
            guard var existingQuote else { return .retainedStale(nil) }
            existingQuote.isStale = true
            return .retainedStale(existingQuote)
        }
    }
}

public protocol LedgerSyncProvider: Sendable {
    var identifier: String { get }
    func pull() async throws -> LedgerState?
    func push(_ state: LedgerState) async throws
}

public struct OfflineOnlySyncProvider: LedgerSyncProvider {
    public let identifier = "offline-only"
    public init() {}
    public func pull() async throws -> LedgerState? { nil }
    public func push(_ state: LedgerState) async throws {}
}
