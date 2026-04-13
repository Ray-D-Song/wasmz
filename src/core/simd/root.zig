// WebAssembly SIMD (128-bit) instruction interpreter.
//
// Implements the full wasm SIMD proposal plus relaxed-SIMD extensions.
// All 128-bit vectors are stored as V128 ({ bytes: [16]u8 }) in little-endian
// byte order.  Internal helpers convert to/from Zig's @Vector for lane-typed
// arithmetic, handling big-endian byte-swap when necessary.
//
// Public API consumed by the VM dispatcher (vm/root.zig):
//   - Classification: classifyOpcode, isSimdOpcode, isRelaxedSimdOpcode, shapeOf, ...
//   - Execution: executeUnary, executeBinary, executeTernary, executeCompare, executeShift
//   - Lane ops: extractLane, replaceLane, shuffleVectors
//   - Memory:   load, store

const classify = @import("classify.zig");
const ops = @import("ops.zig");
const exec = @import("exec.zig");
const memory = @import("memory.zig");

pub const SimdOpcode = classify.SimdOpcode;
pub const SimdShape = classify.SimdShape;
pub const SimdClass = classify.SimdClass;
pub const SimdLoadInfo = classify.SimdLoadInfo;
pub const SimdStoreInfo = classify.SimdStoreInfo;
pub const V128 = ops.V128;
pub const RawVal = exec.RawVal;
pub const SimdVal = exec.SimdVal;

pub const isSimdOpcode = classify.isSimdOpcode;
pub const isRelaxedSimdOpcode = classify.isRelaxedSimdOpcode;
pub const classifyOpcode = classify.classifyOpcode;
pub const shapeOf = classify.shapeOf;
pub const laneCount = classify.laneCount;
pub const laneByteWidth = classify.laneByteWidth;
pub const isLaneLoadOpcode = classify.isLaneLoadOpcode;
pub const isLaneStoreOpcode = classify.isLaneStoreOpcode;
pub const isVectorResultOpcode = classify.isVectorResultOpcode;
pub const isSplatOpcode = classify.isSplatOpcode;
pub const laneImmediateFromOpcode = classify.laneImmediateFromOpcode;

pub const v128FromBytes = ops.v128FromBytes;
pub const bytesFromV128 = ops.bytesFromV128;

pub const executeUnary = exec.executeUnary;
pub const executeBinary = exec.executeBinary;
pub const executeTernary = exec.executeTernary;
pub const executeCompare = exec.executeCompare;
pub const executeShift = exec.executeShift;
pub const extractLane = exec.extractLane;
pub const replaceLane = exec.replaceLane;
pub const shuffleVectors = exec.shuffleVectors;

pub const load = exec.load;
pub const store = exec.store;

test {
    _ = classify;
    _ = ops;
    _ = exec;
    _ = memory;
}
