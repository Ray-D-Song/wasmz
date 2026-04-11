pub const Config = struct {
    simd: bool = true,
    relaxed_simd: bool = true,
    /// Force the legacy exception-handling proposal (try/catch/rethrow/delegate)
    /// instead of auto-detecting from the binary.
    legacy_exceptions: bool = false,
};
