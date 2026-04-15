comptime {
    const zig_atleast_16 = @import("builtin").zig_version.order(.{ .major = 0, .minor = 16, .patch = 0 }) != .lt;
    if (zig_atleast_16) @compileError("this module should only be used on zig 0.15");
}

// pub const AutoHashMap = hash_map.AutoHashMap;
// pub const AutoHashMapUnmanaged = hash_map.AutoHashMapUnmanaged;
// pub const BitStack = @import("BitStack.zig");
// pub const Build = @import("Build.zig");
// pub const BufMap = @import("buf_map.zig").BufMap;
// pub const BufSet = @import("buf_set.zig").BufSet;
// pub const StaticStringMap = static_string_map.StaticStringMap;
// pub const StaticStringMapWithEql = static_string_map.StaticStringMapWithEql;
// pub const Deque = @import("deque.zig").Deque;
// pub const DoublyLinkedList = @import("DoublyLinkedList.zig");
// pub const DynLib = @import("dynamic_library.zig").DynLib;
// pub const DynamicBitSet = bit_set.DynamicBitSet;
// pub const DynamicBitSetUnmanaged = bit_set.DynamicBitSetUnmanaged;
// pub const EnumArray = enums.EnumArray;
// pub const EnumMap = enums.EnumMap;
// pub const EnumSet = enums.EnumSet;
// pub const HashMap = hash_map.HashMap;
// pub const HashMapUnmanaged = hash_map.HashMapUnmanaged;
pub const Io = @import("Io.zig");
// pub const MultiArrayList = @import("multi_array_list.zig").MultiArrayList;
// pub const PriorityQueue = @import("priority_queue.zig").PriorityQueue;
// pub const PriorityDequeue = @import("priority_dequeue.zig").PriorityDequeue;
// pub const Progress = @import("Progress.zig");
// pub const Random = @import("Random.zig");
// pub const SemanticVersion = @import("SemanticVersion.zig");
// pub const SinglyLinkedList = @import("SinglyLinkedList.zig");
// pub const StaticBitSet = bit_set.StaticBitSet;
// pub const StringHashMap = hash_map.StringHashMap;
// pub const StringHashMapUnmanaged = hash_map.StringHashMapUnmanaged;
// pub const Target = @import("Target.zig");
// pub const Thread = @import("Thread.zig");
// pub const Treap = @import("treap.zig").Treap;
// pub const Tz = tz.Tz;
// pub const Uri = @import("Uri.zig");

// /// Deprecated; use `array_hash_map.Custom`.
// pub const ArrayHashMapUnmanaged = array_hash_map.Custom;
// /// Deprecated; use `array_hash_map.Auto`.
// pub const AutoArrayHashMapUnmanaged = array_hash_map.Auto;
// /// Deprecated; use `array_hash_map.String`.
// pub const StringArrayHashMapUnmanaged = array_hash_map.String;

// /// A contiguous, growable list of items in memory. This is a wrapper around a
// /// slice of `T` values.
// ///
// /// The same allocator must be used throughout its entire lifetime. Initialize
// /// directly with `empty` or `initCapacity`, and deinitialize with `deinit` or
// /// `toOwnedSlice`.
// pub fn ArrayList(comptime T: type) type {
//     return array_list.Aligned(T, null);
// }
// pub const array_list = @import("array_list.zig");

// /// Deprecated; use `array_list.Aligned`.
// pub const ArrayListAligned = array_list.Aligned;
// /// Deprecated; use `array_list.Aligned`.
// pub const ArrayListAlignedUnmanaged = array_list.Aligned;
// /// Deprecated; use `ArrayList`.
// pub const ArrayListUnmanaged = ArrayList;

// pub const array_hash_map = @import("array_hash_map.zig");
// pub const atomic = @import("atomic.zig");
// pub const base64 = @import("base64.zig");
// pub const bit_set = @import("bit_set.zig");
// pub const builtin = @import("builtin.zig");
// pub const c = @import("c.zig");
// pub const coff = @import("coff.zig");
// pub const compress = @import("compress.zig");
// pub const static_string_map = @import("static_string_map.zig");
// pub const crypto = @import("crypto.zig");
pub const debug = @import("std").debug;
// pub const dwarf = @import("dwarf.zig");
// pub const elf = @import("elf.zig");
// pub const enums = @import("enums.zig");
// pub const fmt = @import("fmt.zig");
pub const fs = @import("std").fs;
// pub const gpu = @import("gpu.zig");
// pub const hash = @import("hash.zig");
// pub const hash_map = @import("hash_map.zig");
// pub const heap = @import("heap.zig");
// pub const http = @import("http.zig");
// pub const json = @import("json.zig");
// pub const leb = @import("leb128.zig");
// pub const log = @import("log.zig");
// pub const macho = @import("macho.zig");
pub const math = @import("std").math;
pub const mem = @import("std").mem;
// pub const meta = @import("meta.zig");
pub const os = @import("std").os;
// pub const pdb = @import("pdb.zig");
// pub const pie = @import("pie.zig");
pub const posix = @import("std").posix;
pub const process = @import("process.zig");
// pub const sort = @import("sort.zig");
// pub const simd = @import("simd.zig");
// pub const ascii = @import("ascii.zig");
// pub const tar = @import("tar.zig");
pub const testing = @import("std").testing;
pub const time = @import("std").time;
// pub const tz = @import("tz.zig");
// pub const unicode = @import("unicode.zig");
// pub const valgrind = @import("valgrind.zig");
// pub const wasm = @import("wasm.zig");
// pub const zig = @import("zig.zig");
// pub const zip = @import("zip.zig");
// pub const zon = @import("zon.zig");
// pub const start = @import("start.zig");

test {
    testing.refAllDecls(@This());
}
