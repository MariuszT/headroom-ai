import Foundation

/// Decodes `Value` when the JSON actually matches its shape, and quietly gives
/// up — `nil`, not a thrown error — when it does not.
///
/// The banked-reset blocks (`cedar_ember`, `rate_limit_reset_credits`) are a
/// separate feature bolted onto each usage response, undocumented and shaped
/// by observation rather than a spec. A field there that comes back the wrong
/// type must not take the whole response down with it — `fiveHour`, `sevenDay`
/// and the rest decode with Swift's synthesized `Decodable`, which throws for
/// the ENTIRE `Response` the moment any one field mismatches, resets block
/// included. Wrapping just that block in `Lenient` isolates the failure: the
/// windows the panel actually needs still parse, and the resets simply read as
/// absent.
struct Lenient<Value: Decodable>: Decodable {
    let value: Value?

    init(from decoder: Decoder) throws {
        value = try? Value(from: decoder)
    }
}
