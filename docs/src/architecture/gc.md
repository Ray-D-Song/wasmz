# Garbage Collection

wasmz implements the WebAssembly GC proposal with a managed heap.

## GC Proposal Overview

The GC proposal adds:

- **Structs** - Fixed-size records with typed fields
- **Arrays** - Variable-size sequences of typed elements
- **Reference Types** - References to GC heap objects

## GC Algorithm

wasmz uses a **tri-color mark-and-sweep** collector with an explicit worklist.

### Allocation Strategy

The heap uses a **free-list allocator** with bump allocation fallback:

1. **Free-list search** - Find a block >= requested size
2. **Block splitting** - Split if remaining space can hold another FreeBlock
3. **Bump allocation** - Fallback when no suitable free block exists

```zig
pub const GcHeap = struct {
    bytes: []u8,              // Contiguous byte buffer
    free_list: FreeList,       // Singly-linked list of free blocks
    used: u32,                 // Bytes currently in use
    live_objects: ArrayList(AllocationInfo), // Track all allocations
};
```

### Collection Phases

**Phase 1: Mark**

1. Seed worklist with root references (call frames, globals)
2. Process worklist iteratively (BFS traversal):
   - Pop object from worklist
   - Mark object by setting mark bit in header
   - Enqueue all child references
3. Continue until worklist is empty

**Phase 2: Sweep**

1. Iterate all live_objects in reverse
2. If marked: clear mark bit (still live)
3. If unmarked: free the block, remove from live list

```zig
pub fn collect(
    self: *Self,
    roots: []const GcRef,
    composite_types: []const CompositeType,
    struct_layouts: []const ?StructLayout,
    array_layouts: []const ?ArrayLayout,
) void {
    // Mark phase: iterative BFS with explicit worklist
    var worklist = ArrayList(u32){};
    for (roots) |ref| {
        if (ref.isHeapRef()) {
            const hdr = self.header(ref.asHeapIndex());
            if (!hdr.isMarked()) {
                hdr.setMark();
                worklist.append(ref.asHeapIndex());
            }
        }
    }
    
    while (worklist.pop()) |idx| {
        // Trace child references...
    }
    
    // Sweep phase
    for (live_objects) |info| {
        if (hdr.isMarked()) {
            hdr.clearMark();
        } else {
            self.free(info.index, info.size);
        }
    }
}
```

### Why Tri-Color Mark-and-Sweep?

- **No stack overflow** - Explicit worklist avoids deep recursion
- **Simple implementation** - Two-phase algorithm is easy to understand
- **Incremental potential** - Worklist design allows future incremental collection

## Object Layout

Each GC object has:

1. **Header (8 bytes)** - Metadata for GC and type information
2. **Payload** - Field data for structs, length + elements for arrays

```zig
const GcHeader = struct {
    kind_bits: u32,    // High 6 bits = GcKind, bit 0 = mark bit
    type_index: u32,   // Type index for concrete types
};
```

### GcKind

High 6 bits identify the object kind for subtype checking:

| Kind | Description |
|------|-------------|
| `Any` | Top type for references |
| `Eq` | Equality comparable types |
| `I31` | Unboxed 31-bit integer |
| `Struct` | Struct object |
| `Array` | Array object |
| `Func` | Function reference |
| `Extern` | External reference |
| `Exception` | Exception object (internal) |

### Mark Bit

Bit 0 of `kind_bits` is used for the GC mark phase:

```zig
fn setMark(self: *GcHeader) void {
    self.kind_bits |= MARK_BIT;
}

fn isMarked(self: GcHeader) bool {
    return (self.kind_bits & MARK_BIT) != 0;
}
```

## GcRef

References are encoded as 32-bit indices:

```zig
const GcRef = struct {
    // Index 0 = null
    // High bits encode the kind (heap, i31, func, extern)
    
    pub fn isHeapRef(self: GcRef) bool;
    pub fn asHeapIndex(self: GcRef) ?u32;
    pub fn encode(index: u32) GcRef;
};
```

## Heap Types

```zig
const HeapType = union(enum) {
    func: void,
    extern: void,
    any: void,
    eq: void,
    i31: void,
    struct_type: *StructType,
    array_type: *ArrayType,
    // ...
};
```

## Structs

```zig
const StructType = struct {
    fields: []FieldType,
    
    const FieldType = struct {
        type: ValType,
        mutable: bool,
    };
};
```

### WASM Example

```wasm
(type $point (struct (field i32) (field i32)))

(func $create_point (param $x i32) (param $y i32) (result (ref $point))
    struct.new $point
    local.get $x
    local.get $y
)

(func $get_x (param $p (ref $point)) (result i32)
    local.get $p
    struct.get $point 0
)
```

## Arrays

```zig
const ArrayType = struct {
    element_type: ValType,
    mutable: bool,
};
```

### WASM Example

```wasm
(type $int_array (array (mut i32)))

(func $create_array (param $len i32) (result (ref $int_array))
    local.get $len
    i32.const 0
    array.new $int_array
)

(func $get_element (param $arr (ref $int_array)) (param $idx i32) (result i32)
    local.get $arr
    local.get $idx
    array.get $int_array
)
```

## i31 References

Small integers stored unboxed:

```zig
const i31ref = struct {
    value: i31,  // 31-bit signed integer
};
```

### WASM Example

```wasm
(func $wrap_i31 (param $i i32) (result (ref i31))
    ref.i31
    local.get $i
)

(func $unwrap_i31 (param $r (ref i31)) (result i32)
    local.get $r
    i31.get_s
)
```

## Key Files

| File | Purpose |
|------|---------|
| `src/vm/gc/root.zig` | GC entry point |
| `src/vm/gc/heap.zig` | Heap management |
| `src/vm/gc/header.zig` | Object header |
| `src/vm/gc/layout.zig` | Object layout calculation |
| `src/core/gc_ref.zig` | Reference type |
| `src/core/heap_type.zig` | Heap type definitions |
| `src/core/ref_type.zig` | Reference type definitions |

## Memory Management

### Allocation

```zig
// In struct.new or array.new
const total_size = HEADER_SIZE + payload_size;
const ref = gc_heap.alloc(total_size) orelse return error.OutOfMemory;

// Initialize header
const hdr = gc_heap.getHeader(ref);
hdr.kind_bits = GcKind.Struct;
hdr.type_index = type_index;

// Initialize fields...
```

### Heap Growth

The heap grows exponentially (2x) when full:

```zig
const new_len = @max(min_needed, current_size * 2);
self.bytes = self.allocator.realloc(self.bytes, new_len);
```

### Collection Trigger

Collection is triggered when memory limit is exceeded:

```zig
if (self.budget) |b| {
    if (!b.canGrow(additional)) {
        // Trigger GC and retry
        gc_heap.collect(roots, composite_types, layouts);
    }
}
```

### No Write Barriers

Since wasmz uses mark-and-sweep, **no write barriers are needed**. References are traced during the mark phase by walking the object graph from roots.

