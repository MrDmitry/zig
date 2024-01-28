const std = @import("std");
const ConfigHeader = @This();
const Step = std.Build.Step;
const Allocator = std.mem.Allocator;

const ConfigError = error{
    InvalidCharacter,
    UndefinedVariable,
    UnusedVariable,
};

pub const ValidatorStrategyType = enum {
    default,
    strict,
};

pub const CMakeStyle = struct {
    source: std.Build.LazyPath,
    validator: ValidatorStrategyType = .default,
};

pub const Style = union(enum) {
    /// The configure format supported by autotools. It uses `#undef foo` to
    /// mark lines that can be substituted with different values.
    autoconf: std.Build.LazyPath,
    /// The configure format supported by CMake. It uses `@FOO@`, `${}` and
    /// `#cmakedefine` for template substitution.
    cmake: CMakeStyle,
    /// Instead of starting with an input file, start with nothing.
    blank,
    /// Start with nothing, like blank, and output a nasm .asm file.
    nasm,

    pub fn getPath(style: Style) ?std.Build.LazyPath {
        switch (style) {
            .autoconf => |s| return s,
            .cmake => |s| return s.source,
            .blank, .nasm => return null,
        }
    }
};

pub const Value = union(enum) {
    undef,
    defined,
    boolean: bool,
    int: i64,
    ident: []const u8,
    string: []const u8,
};

const ValidatorStrategy = struct {
    const Self = @This();

    arena: std.heap.ArenaAllocator,
    strategy: ValidatorStrategyType,
    keys: ?std.StringArrayHashMapUnmanaged(void),

    fn init(allocator: Allocator, strategy: ValidatorStrategyType) !Self {
        return switch (strategy) {
            .default => Self{
                .arena = undefined,
                .strategy = strategy,
                .keys = null,
            },
            .strict => Self{
                .arena = std.heap.ArenaAllocator.init(allocator),
                .strategy = strategy,
                .keys = try std.StringArrayHashMapUnmanaged(void).init(allocator, &[0][]const u8{}, &[0]void{}),
            },
        };
    }

    fn deinit(self: *Self) void {
        switch (self.strategy) {
            .default => {},
            .strict => {
                self.arena.deinit();
            },
        }
        self.* = undefined;
    }

    fn checkError(self: *Self, err: ConfigError) ConfigError!void {
        return switch (self.strategy) {
            .default => switch (err) {
                ConfigError.InvalidCharacter => err,
                else => {
                    // suppress other errors
                },
            },
            .strict => err,
        };
    }

    fn useKey(self: *Self, key: []const u8) !void {
        switch (self.strategy) {
            .default => {},
            .strict => {
                if (self.keys) |*keys| {
                    if (!keys.contains(key)) {
                        const key_clone = try self.arena.allocator().dupe(u8, key);
                        try keys.put(self.arena.allocator(), key_clone, void{});
                    }
                }
            },
        }
    }

    fn usedKeys(self: *Self) ?[][]const u8 {
        return switch (self.strategy) {
            .default => null,
            .strict => {
                if (self.keys) |*keys| {
                    return keys.keys();
                } else unreachable;
            },
        };
    }
};

step: Step,
values: std.StringArrayHashMap(Value),
output_file: std.Build.GeneratedFile,

style: Style,
max_bytes: usize,
include_path: []const u8,
include_guard_override: ?[]const u8,

pub const base_id: Step.Id = .config_header;

pub const Options = struct {
    style: Style = .blank,
    max_bytes: usize = 2 * 1024 * 1024,
    include_path: ?[]const u8 = null,
    first_ret_addr: ?usize = null,
    include_guard_override: ?[]const u8 = null,
};

pub fn create(owner: *std.Build, options: Options) *ConfigHeader {
    const self = owner.allocator.create(ConfigHeader) catch @panic("OOM");

    var include_path: []const u8 = "config.h";

    if (options.style.getPath()) |s| default_include_path: {
        const sub_path = switch (s) {
            .path => |path| path,
            .generated, .generated_dirname => break :default_include_path,
            .cwd_relative => |sub_path| sub_path,
            .dependency => |dependency| dependency.sub_path,
        };
        const basename = std.fs.path.basename(sub_path);
        if (std.mem.endsWith(u8, basename, ".h.in")) {
            include_path = basename[0 .. basename.len - 3];
        }
    }

    if (options.include_path) |p| {
        include_path = p;
    }

    const name = if (options.style.getPath()) |s|
        owner.fmt("configure {s} header {s} to {s}", .{
            @tagName(options.style), s.getDisplayName(), include_path,
        })
    else
        owner.fmt("configure {s} header to {s}", .{ @tagName(options.style), include_path });

    self.* = .{
        .step = Step.init(.{
            .id = base_id,
            .name = name,
            .owner = owner,
            .makeFn = make,
            .first_ret_addr = options.first_ret_addr orelse @returnAddress(),
        }),
        .style = options.style,
        .values = std.StringArrayHashMap(Value).init(owner.allocator),

        .max_bytes = options.max_bytes,
        .include_path = include_path,
        .include_guard_override = options.include_guard_override,
        .output_file = .{ .step = &self.step },
    };

    return self;
}

pub fn addValues(self: *ConfigHeader, values: anytype) void {
    return addValuesInner(self, values) catch @panic("OOM");
}

pub fn getOutput(self: *ConfigHeader) std.Build.LazyPath {
    return .{ .generated = &self.output_file };
}

fn addValuesInner(self: *ConfigHeader, values: anytype) !void {
    inline for (@typeInfo(@TypeOf(values)).Struct.fields) |field| {
        try putValue(self, field.name, field.type, @field(values, field.name));
    }
}

fn putValue(self: *ConfigHeader, field_name: []const u8, comptime T: type, v: T) !void {
    switch (@typeInfo(T)) {
        .Null => {
            try self.values.put(field_name, .undef);
        },
        .Void => {
            try self.values.put(field_name, .defined);
        },
        .Bool => {
            try self.values.put(field_name, .{ .boolean = v });
        },
        .Int => {
            try self.values.put(field_name, .{ .int = v });
        },
        .ComptimeInt => {
            try self.values.put(field_name, .{ .int = v });
        },
        .EnumLiteral => {
            try self.values.put(field_name, .{ .ident = @tagName(v) });
        },
        .Optional => {
            if (v) |x| {
                return putValue(self, field_name, @TypeOf(x), x);
            } else {
                try self.values.put(field_name, .undef);
            }
        },
        .Pointer => |ptr| {
            switch (@typeInfo(ptr.child)) {
                .Array => |array| {
                    if (ptr.size == .One and array.child == u8) {
                        try self.values.put(field_name, .{ .string = v });
                        return;
                    }
                },
                .Int => {
                    if (ptr.size == .Slice and ptr.child == u8) {
                        try self.values.put(field_name, .{ .string = v });
                        return;
                    }
                },
                else => {},
            }

            @compileError("unsupported ConfigHeader value type: " ++ @typeName(T));
        },
        else => @compileError("unsupported ConfigHeader value type: " ++ @typeName(T)),
    }
}

fn make(step: *Step, prog_node: *std.Progress.Node) !void {
    _ = prog_node;
    const b = step.owner;
    const self = @fieldParentPtr(ConfigHeader, "step", step);
    const gpa = b.allocator;
    const arena = b.allocator;

    var man = b.cache.obtain();
    defer man.deinit();

    // Random bytes to make ConfigHeader unique. Refresh this with new
    // random bytes when ConfigHeader implementation is modified in a
    // non-backwards-compatible way.
    man.hash.add(@as(u32, 0xdef08d23));
    man.hash.addBytes(self.include_path);
    man.hash.addOptionalBytes(self.include_guard_override);

    var output = std.ArrayList(u8).init(gpa);
    defer output.deinit();

    const header_text = "This file was generated by ConfigHeader using the Zig Build System.";
    const c_generated_line = "/* " ++ header_text ++ " */\n";
    const asm_generated_line = "; " ++ header_text ++ "\n";

    switch (self.style) {
        .autoconf => |file_source| {
            try output.appendSlice(c_generated_line);
            const src_path = file_source.getPath(b);
            const contents = try std.fs.cwd().readFileAlloc(arena, src_path, self.max_bytes);
            try render_autoconf(step, contents, &output, self.values, src_path);
        },
        .cmake => |style| {
            try output.appendSlice(c_generated_line);
            const src_path = style.source.getPath(b);
            const contents = try std.fs.cwd().readFileAlloc(arena, src_path, self.max_bytes);
            try render_cmake(step, contents, &output, self.values, src_path);
        },
        .blank => {
            try output.appendSlice(c_generated_line);
            try render_blank(&output, self.values, self.include_path, self.include_guard_override);
        },
        .nasm => {
            try output.appendSlice(asm_generated_line);
            try render_nasm(&output, self.values);
        },
    }

    man.hash.addBytes(output.items);

    if (try step.cacheHit(&man)) {
        const digest = man.final();
        self.output_file.path = try b.cache_root.join(arena, &.{
            "o", &digest, self.include_path,
        });
        return;
    }

    const digest = man.final();

    // If output_path has directory parts, deal with them.  Example:
    // output_dir is zig-cache/o/HASH
    // output_path is libavutil/avconfig.h
    // We want to open directory zig-cache/o/HASH/libavutil/
    // but keep output_dir as zig-cache/o/HASH for -I include
    const sub_path = try std.fs.path.join(arena, &.{ "o", &digest, self.include_path });
    const sub_path_dirname = std.fs.path.dirname(sub_path).?;

    b.cache_root.handle.makePath(sub_path_dirname) catch |err| {
        return step.fail("unable to make path '{}{s}': {s}", .{
            b.cache_root, sub_path_dirname, @errorName(err),
        });
    };

    b.cache_root.handle.writeFile(sub_path, output.items) catch |err| {
        return step.fail("unable to write file '{}{s}': {s}", .{
            b.cache_root, sub_path, @errorName(err),
        });
    };

    self.output_file.path = try b.cache_root.join(arena, &.{sub_path});
    try man.writeManifest();
}

fn render_autoconf(
    step: *Step,
    contents: []const u8,
    output: *std.ArrayList(u8),
    values: std.StringArrayHashMap(Value),
    src_path: []const u8,
) !void {
    var values_copy = try values.clone();
    defer values_copy.deinit();

    var any_errors = false;
    var line_index: u32 = 0;
    var line_it = std.mem.splitScalar(u8, contents, '\n');
    while (line_it.next()) |line| : (line_index += 1) {
        if (!std.mem.startsWith(u8, line, "#")) {
            try output.appendSlice(line);
            try output.appendSlice("\n");
            continue;
        }
        var it = std.mem.tokenizeAny(u8, line[1..], " \t\r");
        const undef = it.next().?;
        if (!std.mem.eql(u8, undef, "undef")) {
            try output.appendSlice(line);
            try output.appendSlice("\n");
            continue;
        }
        const name = it.rest();
        const kv = values_copy.fetchSwapRemove(name) orelse {
            try step.addError("{s}:{d}: error: unspecified config header value: '{s}'", .{
                src_path, line_index + 1, name,
            });
            any_errors = true;
            continue;
        };
        try renderValueC(output, name, kv.value);
    }

    for (values_copy.keys()) |name| {
        try step.addError("{s}: error: config header value unused: '{s}'", .{ src_path, name });
        any_errors = true;
    }

    if (any_errors) {
        return error.MakeFailed;
    }
}

fn render_cmake(
    step: *Step,
    contents: []const u8,
    output: *std.ArrayList(u8),
    values: std.StringArrayHashMap(Value),
    src_path: []const u8,
) !void {
    const self = @fieldParentPtr(ConfigHeader, "step", step);
    const build = step.owner;
    const allocator = build.allocator;

    const style = switch (self.style) {
        .cmake => |c| c,
        else => unreachable,
    };

    var validator = try ValidatorStrategy.init(allocator, style.validator);
    defer validator.deinit();

    var values_copy = try values.clone();
    defer values_copy.deinit();

    var any_errors = false;
    var line_index: u32 = 0;
    var line_it = std.mem.splitScalar(u8, contents, '\n');
    while (line_it.next()) |raw_line| : (line_index += 1) {
        const last_line = line_it.index == line_it.buffer.len;

        const line = expand_variables_cmake(allocator, &validator, raw_line, values) catch |err| switch (err) {
            ConfigError.InvalidCharacter => {
                try step.addError("{s}:{d}: error: invalid character in a variable name", .{
                    src_path, line_index + 1,
                });
                any_errors = true;
                continue;
            },
            else => {
                try step.addError("{s}:{d}: unable to substitute variable: error: {s}", .{
                    src_path, line_index + 1, @errorName(err),
                });
                any_errors = true;
                continue;
            },
        };
        defer allocator.free(line);

        if (!std.mem.startsWith(u8, line, "#")) {
            try output.appendSlice(line);
            if (!last_line) {
                try output.appendSlice("\n");
            }
            continue;
        }
        var it = std.mem.tokenizeAny(u8, line[1..], " \t\r");
        const cmakedefine = it.next().?;
        if (!std.mem.eql(u8, cmakedefine, "cmakedefine") and
            !std.mem.eql(u8, cmakedefine, "cmakedefine01"))
        {
            try output.appendSlice(line);
            if (!last_line) {
                try output.appendSlice("\n");
            }
            continue;
        }

        const booldefine = std.mem.eql(u8, cmakedefine, "cmakedefine01");

        const name = it.next() orelse {
            try step.addError("{s}:{d}: error: missing define name", .{
                src_path, line_index + 1,
            });
            any_errors = true;
            continue;
        };
        var value = values_copy.get(name) orelse blk: {
            if (booldefine) {
                break :blk Value{ .int = 0 };
            }
            break :blk Value.undef;
        };

        value = blk: {
            switch (value) {
                .boolean => |b| {
                    if (!b) {
                        break :blk Value.undef;
                    }
                },
                .int => |i| {
                    if (i == 0) {
                        break :blk Value.undef;
                    }
                },
                .string => |string| {
                    if (string.len == 0) {
                        break :blk Value.undef;
                    }
                },

                else => {},
            }
            break :blk value;
        };

        if (booldefine) {
            value = blk: {
                switch (value) {
                    .undef => {
                        break :blk Value{ .boolean = false };
                    },
                    .defined => {
                        break :blk Value{ .boolean = false };
                    },
                    .boolean => |b| {
                        break :blk Value{ .boolean = b };
                    },
                    .int => |i| {
                        break :blk Value{ .boolean = i != 0 };
                    },
                    .string => |string| {
                        break :blk Value{ .boolean = string.len != 0 };
                    },

                    else => {
                        break :blk Value{ .boolean = false };
                    },
                }
            };
        } else if (value != Value.undef) {
            value = Value{ .ident = it.rest() };
        }

        try renderValueC(output, name, value);
    }

    if (style.validator == .strict) {
        if (validator.usedKeys()) |used_keys| {
            for (used_keys) |key| {
                _ = values_copy.fetchSwapRemove(key) orelse {
                    try step.addError("error: undefined variable: {s}", .{
                        key,
                    });
                    any_errors = true;
                };
            }

            if (values_copy.count() > 0) {
                try step.addError("error: unused variable: {s}", .{
                    values_copy.keys(),
                });
                any_errors = true;
            }
        }
    }

    if (any_errors) {
        return error.HeaderConfigFailed;
    }
}

fn render_blank(
    output: *std.ArrayList(u8),
    defines: std.StringArrayHashMap(Value),
    include_path: []const u8,
    include_guard_override: ?[]const u8,
) !void {
    const include_guard_name = include_guard_override orelse blk: {
        const name = try output.allocator.dupe(u8, include_path);
        for (name) |*byte| {
            switch (byte.*) {
                'a'...'z' => byte.* = byte.* - 'a' + 'A',
                'A'...'Z', '0'...'9' => continue,
                else => byte.* = '_',
            }
        }
        break :blk name;
    };

    try output.appendSlice("#ifndef ");
    try output.appendSlice(include_guard_name);
    try output.appendSlice("\n#define ");
    try output.appendSlice(include_guard_name);
    try output.appendSlice("\n");

    const values = defines.values();
    for (defines.keys(), 0..) |name, i| {
        try renderValueC(output, name, values[i]);
    }

    try output.appendSlice("#endif /* ");
    try output.appendSlice(include_guard_name);
    try output.appendSlice(" */\n");
}

fn render_nasm(output: *std.ArrayList(u8), defines: std.StringArrayHashMap(Value)) !void {
    const values = defines.values();
    for (defines.keys(), 0..) |name, i| {
        try renderValueNasm(output, name, values[i]);
    }
}

fn renderValueC(output: *std.ArrayList(u8), name: []const u8, value: Value) !void {
    switch (value) {
        .undef => {
            try output.appendSlice("/* #undef ");
            try output.appendSlice(name);
            try output.appendSlice(" */\n");
        },
        .defined => {
            try output.appendSlice("#define ");
            try output.appendSlice(name);
            try output.appendSlice("\n");
        },
        .boolean => |b| {
            try output.appendSlice("#define ");
            try output.appendSlice(name);
            try output.appendSlice(if (b) " 1\n" else " 0\n");
        },
        .int => |i| {
            try output.writer().print("#define {s} {d}\n", .{ name, i });
        },
        .ident => |ident| {
            try output.writer().print("#define {s} {s}\n", .{ name, ident });
        },
        .string => |string| {
            // TODO: use C-specific escaping instead of zig string literals
            try output.writer().print("#define {s} \"{}\"\n", .{ name, std.zig.fmtEscapes(string) });
        },
    }
}

fn renderValueNasm(output: *std.ArrayList(u8), name: []const u8, value: Value) !void {
    switch (value) {
        .undef => {
            try output.appendSlice("; %undef ");
            try output.appendSlice(name);
            try output.appendSlice("\n");
        },
        .defined => {
            try output.appendSlice("%define ");
            try output.appendSlice(name);
            try output.appendSlice("\n");
        },
        .boolean => |b| {
            try output.appendSlice("%define ");
            try output.appendSlice(name);
            try output.appendSlice(if (b) " 1\n" else " 0\n");
        },
        .int => |i| {
            try output.writer().print("%define {s} {d}\n", .{ name, i });
        },
        .ident => |ident| {
            try output.writer().print("%define {s} {s}\n", .{ name, ident });
        },
        .string => |string| {
            // TODO: use nasm-specific escaping instead of zig string literals
            try output.writer().print("%define {s} \"{}\"\n", .{ name, std.zig.fmtEscapes(string) });
        },
    }
}

fn expand_variables_cmake(
    allocator: Allocator,
    validator: *ValidatorStrategy,
    contents: []const u8,
    values: std.StringArrayHashMap(Value),
) ![]const u8 {
    var result = std.ArrayList(u8).init(allocator);
    errdefer result.deinit();

    const valid_varname_chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789/_.+-";
    const open_var = "${";

    var curr: usize = 0;
    var source_offset: usize = 0;
    const Position = struct {
        source: usize,
        target: usize,
    };
    var var_stack = std.ArrayList(Position).init(allocator);
    defer var_stack.deinit();
    loop: while (curr < contents.len) : (curr += 1) {
        switch (contents[curr]) {
            '@' => blk: {
                if (std.mem.indexOfScalarPos(u8, contents, curr + 1, '@')) |close_pos| {
                    if (close_pos == curr + 1) {
                        // closed immediately, preserve as a literal
                        break :blk;
                    }
                    const valid_varname_end = std.mem.indexOfNonePos(u8, contents, curr + 1, valid_varname_chars) orelse 0;
                    if (valid_varname_end != close_pos) {
                        // contains invalid characters, preserve as a literal
                        break :blk;
                    }

                    const key = contents[curr + 1 .. close_pos];
                    if (!values.contains(key)) {
                        try validator.checkError(ConfigError.UndefinedVariable);
                    } else {
                        try validator.useKey(key);
                    }
                    const value = values.get(key) orelse .undef;
                    const missing = contents[source_offset..curr];
                    try result.appendSlice(missing);
                    switch (value) {
                        .undef, .defined => {},
                        .boolean => |b| {
                            try result.append(if (b) '1' else '0');
                        },
                        .int => |i| {
                            try result.writer().print("{d}", .{i});
                        },
                        .ident, .string => |s| {
                            try result.appendSlice(s);
                        },
                    }

                    curr = close_pos;
                    source_offset = close_pos + 1;

                    continue :loop;
                }
            },
            '$' => blk: {
                const next = curr + 1;
                if (next == contents.len or contents[next] != '{') {
                    // no open bracket detected, preserve as a literal
                    break :blk;
                }
                const missing = contents[source_offset..curr];
                try result.appendSlice(missing);
                try result.appendSlice(open_var);

                source_offset = curr + open_var.len;
                curr = next;
                try var_stack.append(Position{
                    .source = curr,
                    .target = result.items.len - open_var.len,
                });

                continue :loop;
            },
            '}' => blk: {
                if (var_stack.items.len == 0) {
                    // no open bracket, preserve as a literal
                    break :blk;
                }
                const open_pos = var_stack.pop();
                if (source_offset == open_pos.source) {
                    source_offset += open_var.len;
                }
                const missing = contents[source_offset..curr];
                try result.appendSlice(missing);

                const key_start = open_pos.target + open_var.len;
                const key = result.items[key_start..];
                if (!values.contains(key)) {
                    try validator.checkError(ConfigError.UndefinedVariable);
                } else {
                    try validator.useKey(key);
                }
                const value = values.get(key) orelse .undef;
                result.shrinkRetainingCapacity(result.items.len - key.len - open_var.len);
                switch (value) {
                    .undef, .defined => {},
                    .boolean => |b| {
                        try result.append(if (b) '1' else '0');
                    },
                    .int => |i| {
                        try result.writer().print("{d}", .{i});
                    },
                    .ident, .string => |s| {
                        try result.appendSlice(s);
                    },
                }

                source_offset = curr + 1;

                continue :loop;
            },
            '\\' => {
                // backslash is not considered a special character
                continue :loop;
            },
            else => {},
        }

        if (var_stack.items.len > 0 and std.mem.indexOfScalar(u8, valid_varname_chars, contents[curr]) == null) {
            try validator.checkError(ConfigError.InvalidCharacter);
        }
    }

    if (source_offset != contents.len) {
        const missing = contents[source_offset..];
        try result.appendSlice(missing);
    }

    return result.toOwnedSlice();
}

const TestHarness = struct {
    const Self = @This();

    allocator: Allocator,
    validator: ValidatorStrategy,
    values: std.StringArrayHashMap(Value),

    fn init(allocator: Allocator, strategy: ValidatorStrategyType) !Self {
        return Self{
            .allocator = allocator,
            .validator = try ValidatorStrategy.init(allocator, strategy),
            .values = std.StringArrayHashMap(Value).init(allocator),
        };
    }

    fn deinit(self: *Self) void {
        self.validator.deinit();
        self.values.deinit();
    }

    fn addValue(self: *Self, key: []const u8, value: Value) !void {
        try self.values.putNoClobber(key, value);
    }

    fn expandVariables(
        self: *Self,
        contents: []const u8,
        expected: []const u8,
    ) !void {
        const actual = try expand_variables_cmake(self.allocator, &self.validator, contents, self.values);
        defer self.allocator.free(actual);

        try std.testing.expectEqualStrings(expected, actual);
    }
};

test "expand_variables_cmake simple cases" {
    const allocator = std.testing.allocator;

    var harness = try TestHarness.init(allocator, .default);
    defer harness.deinit();

    try harness.addValue("undef", .undef);
    try harness.addValue("defined", .defined);
    try harness.addValue("true", Value{ .boolean = true });
    try harness.addValue("false", Value{ .boolean = false });
    try harness.addValue("int", Value{ .int = 42 });
    try harness.addValue("ident", Value{ .string = "value" });
    try harness.addValue("string", Value{ .string = "text" });

    // empty strings are preserved
    try harness.expandVariables("", "");

    // line with misc content is preserved
    try harness.expandVariables("no substitution", "no substitution");

    // empty ${} wrapper is removed
    try harness.expandVariables("${}", "");

    // empty @ sigils are preserved
    try harness.expandVariables("@", "@");
    try harness.expandVariables("@@", "@@");
    try harness.expandVariables("@@@", "@@@");
    try harness.expandVariables("@@@@", "@@@@");

    // simple substitution
    try harness.expandVariables("@undef@", "");
    try harness.expandVariables("${undef}", "");
    try harness.expandVariables("@defined@", "");
    try harness.expandVariables("${defined}", "");
    try harness.expandVariables("@true@", "1");
    try harness.expandVariables("${true}", "1");
    try harness.expandVariables("@false@", "0");
    try harness.expandVariables("${false}", "0");
    try harness.expandVariables("@int@", "42");
    try harness.expandVariables("${int}", "42");
    try harness.expandVariables("@ident@", "value");
    try harness.expandVariables("${ident}", "value");
    try harness.expandVariables("@string@", "text");
    try harness.expandVariables("${string}", "text");

    // double packed substitution
    try harness.expandVariables("@string@@string@", "texttext");
    try harness.expandVariables("${string}${string}", "texttext");

    // triple packed substitution
    try harness.expandVariables("@string@@int@@string@", "text42text");
    try harness.expandVariables("@string@${int}@string@", "text42text");
    try harness.expandVariables("${string}@int@${string}", "text42text");
    try harness.expandVariables("${string}${int}${string}", "text42text");

    // double separated substitution
    try harness.expandVariables("@int@.@int@", "42.42");
    try harness.expandVariables("${int}.${int}", "42.42");

    // triple separated substitution
    try harness.expandVariables("@int@.@true@.@int@", "42.1.42");
    try harness.expandVariables("@int@.${true}.@int@", "42.1.42");
    try harness.expandVariables("${int}.@true@.${int}", "42.1.42");
    try harness.expandVariables("${int}.${true}.${int}", "42.1.42");

    // misc prefix is preserved
    try harness.expandVariables("false is @false@", "false is 0");
    try harness.expandVariables("false is ${false}", "false is 0");

    // misc suffix is preserved
    try harness.expandVariables("@true@ is true", "1 is true");
    try harness.expandVariables("${true} is true", "1 is true");

    // surrounding content is preserved
    try harness.expandVariables("what is 6*7? @int@!", "what is 6*7? 42!");
    try harness.expandVariables("what is 6*7? ${int}!", "what is 6*7? 42!");

    // incomplete key is preserved
    try harness.expandVariables("@undef", "@undef");
    try harness.expandVariables("${undef", "${undef");
    try harness.expandVariables("{undef}", "{undef}");
    try harness.expandVariables("undef@", "undef@");
    try harness.expandVariables("undef}", "undef}");

    // unknown key is removed
    try harness.expandVariables("@bad@", "");
    try harness.expandVariables("${bad}", "");
}

test "expand_variables_cmake edge cases" {
    const allocator = std.testing.allocator;

    var harness = try TestHarness.init(allocator, .default);
    defer harness.deinit();

    // special symbols
    try harness.addValue("at", Value{ .string = "@" });
    try harness.addValue("dollar", Value{ .string = "$" });
    try harness.addValue("underscore", Value{ .string = "_" });

    // basic value
    try harness.addValue("string", Value{ .string = "text" });

    // proxy case values
    try harness.addValue("string_proxy", Value{ .string = "string" });
    try harness.addValue("string_at", Value{ .string = "@string@" });
    try harness.addValue("string_curly", Value{ .string = "{string}" });
    try harness.addValue("string_var", Value{ .string = "${string}" });

    // stack case values
    try harness.addValue("nest_underscore_proxy", Value{ .string = "underscore" });
    try harness.addValue("nest_proxy", Value{ .string = "nest_underscore_proxy" });

    // @-vars resolved only when they wrap valid characters, otherwise considered literals
    try harness.expandVariables("@@string@@", "@text@");
    try harness.expandVariables("@${string}@", "@text@");

    // @-vars are resolved inside ${}-vars
    try harness.expandVariables("${@string_proxy@}", "text");

    // expanded variables are considered strings after expansion
    try harness.expandVariables("@string_at@", "@string@");
    try harness.expandVariables("${string_at}", "@string@");
    try harness.expandVariables("$@string_curly@", "${string}");
    try harness.expandVariables("$${string_curly}", "${string}");
    try harness.expandVariables("${string_var}", "${string}");
    try harness.expandVariables("@string_var@", "${string}");
    try harness.expandVariables("${dollar}{${string}}", "${text}");
    try harness.expandVariables("@dollar@{${string}}", "${text}");
    try harness.expandVariables("@dollar@{@string@}", "${text}");

    // when expanded variables contain invalid characters, they prevent further expansion
    try harness.expandVariables("${${string_var}}", "");
    try harness.expandVariables("${@string_var@}", "");

    // nested expanded variables are expanded from the inside out
    try harness.expandVariables("${string${underscore}proxy}", "string");
    try harness.expandVariables("${string@underscore@proxy}", "string");

    // nested vars are only expanded when ${} is closed
    try harness.expandVariables("@nest@underscore@proxy@", "underscore");
    try harness.expandVariables("${nest${underscore}proxy}", "nest_underscore_proxy");
    try harness.expandVariables("@nest@@nest_underscore@underscore@proxy@@proxy@", "underscore");
    try harness.expandVariables("${nest${${nest_underscore${underscore}proxy}}proxy}", "nest_underscore_proxy");

    // invalid characters lead to an error
    try std.testing.expectError(ConfigError.InvalidCharacter, harness.expandVariables("${str*ing}", ""));
    try std.testing.expectError(ConfigError.InvalidCharacter, harness.expandVariables("${str$ing}", ""));
    try std.testing.expectError(ConfigError.InvalidCharacter, harness.expandVariables("${str@ing}", ""));
}

test "expand_variables_cmake escaped characters" {
    const allocator = std.testing.allocator;
    var harness = try TestHarness.init(allocator, .default);
    defer harness.deinit();

    try harness.addValue("string", Value{ .string = "text" });

    // backslash is an invalid character for @ lookup
    try harness.expandVariables("\\@string\\@", "\\@string\\@");

    // backslash is preserved, but doesn't affect ${} variable expansion
    try harness.expandVariables("\\${string}", "\\text");

    // backslash breaks ${} opening bracket identification
    try harness.expandVariables("$\\{string}", "$\\{string}");

    // backslash is skipped when checking for invalid characters, yet it mangles the key
    try harness.expandVariables("${string\\}", "");
}

test "expand_variables_cmake strict validator" {
    const allocator = std.testing.allocator;

    var harness = try TestHarness.init(allocator, .strict);
    defer harness.deinit();

    try harness.addValue("string", Value{ .string = "text" });

    // normal substitution works
    try harness.expandVariables("${string}", "text");

    // invalid character leads to an error
    try std.testing.expectError(ConfigError.InvalidCharacter, harness.expandVariables("${str!ng}", ""));

    // mangled key in @-capture is not considered an error, but a literal
    try harness.expandVariables("\\@string\\@", "\\@string\\@");

    // mangled key leads to an error
    try std.testing.expectError(ConfigError.UndefinedVariable, harness.expandVariables("${string\\}", ""));
}
