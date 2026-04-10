const std = @import("std");
const testing = std.testing;

const payload = @import("payload");
const core = @import("core");
const translate_mod = @import("../translate.zig");

const Type = payload.Type;
const ValType = core.ValType;

test "wasmValTypeFromType handles GC reference types" {
    const anyref_type = Type{ .kind = .anyref };
    try testing.expectEqual(ValType.anyref(), try translate_mod.wasmValTypeFromType(anyref_type));

    const eqref_type = Type{ .kind = .eqref };
    try testing.expectEqual(ValType.eqref(), try translate_mod.wasmValTypeFromType(eqref_type));

    const i31ref_type = Type{ .kind = .i31ref };
    try testing.expectEqual(ValType.i31ref(), try translate_mod.wasmValTypeFromType(i31ref_type));

    const structref_type = Type{ .kind = .structref };
    try testing.expectEqual(ValType.structref(), try translate_mod.wasmValTypeFromType(structref_type));

    const arrayref_type = Type{ .kind = .arrayref };
    try testing.expectEqual(ValType.arrayref(), try translate_mod.wasmValTypeFromType(arrayref_type));

    const null_funcref = Type{ .kind = .null_funcref };
    try testing.expectEqual(ValType.nullfuncref(), try translate_mod.wasmValTypeFromType(null_funcref));

    const null_externref = Type{ .kind = .null_externref };
    try testing.expectEqual(ValType.nullexternref(), try translate_mod.wasmValTypeFromType(null_externref));

    const null_ref = Type{ .kind = .null_ref };
    try testing.expectEqual(ValType.nullref(), try translate_mod.wasmValTypeFromType(null_ref));

    const ref_type_payload = payload.RefType{
        .nullable = true,
        .ref_index = .{ .index = 5 },
    };
    const concrete_ref_type = Type{ .ref_type = ref_type_payload };
    const result = try translate_mod.wasmValTypeFromType(concrete_ref_type);
    try testing.expect(result == .Ref);
    try testing.expect(result.Ref.nullable);
    try testing.expect(result.Ref.heap_type.isConcrete());
    try testing.expectEqual(@as(u32, 5), result.Ref.heap_type.concreteType().?);
}
