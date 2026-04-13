pub const Config = struct {
    simd: bool = true,
    relaxed_simd: bool = true,
    /// Force the legacy exception-handling proposal (try/catch/rethrow/delegate)
    /// instead of auto-detecting from the binary.
    legacy_exceptions: bool = false,
    /// Maximum total memory allowed (linear + GC heap + shared), in bytes.
    /// null means unlimited.
    mem_limit_bytes: ?u64 = null,
    /// When true, all local functions are compiled up front during Module.compile()
    /// instead of lazily on first call.  This trades higher startup cost for
    /// zero lazy-compilation overhead at runtime.
    eager_compile: bool = false,
};
