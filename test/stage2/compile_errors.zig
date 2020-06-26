const TestContext = @import("../../src-self-hosted/test.zig").TestContext;
const std = @import("std");

const ErrorMsg = @import("../../src-self-hosted/Module.zig").ErrorMsg;

const linux_x64 = std.zig.CrossTarget{
    .cpu_arch = .x86_64,
    .os_tag = .linux,
};

pub fn addCases(ctx: *TestContext) !void {
    ctx.compileErrorZIR("call undefined local", linux_x64,
        \\@noreturn = primitive(noreturn)
        \\
        \\@start_fnty = fntype([], @noreturn, cc=Naked)
        \\@start = fn(@start_fnty, {
        \\  %0 = call(%test, [])
        \\})
 // TODO: address inconsistency in this message and the one in the next test
            , &[_][]const u8{":5:13: error: unrecognized identifier: %test"});

    ctx.compileErrorZIR("call with non-existent target", linux_x64,
        \\@noreturn = primitive(noreturn)
        \\
        \\@start_fnty = fntype([], @noreturn, cc=Naked)
        \\@start = fn(@start_fnty, {
        \\  %0 = call(@notafunc, [])
        \\})
        \\@0 = str("_start")
        \\@1 = export(@0, "start")
    , &[_][]const u8{":5:13: error: decl 'notafunc' not found"});

    // TODO: this error should occur at the call site, not the fntype decl
    ctx.compileErrorZIR("call naked function", linux_x64,
        \\@noreturn = primitive(noreturn)
        \\
        \\@start_fnty = fntype([], @noreturn, cc=Naked)
        \\@s = fn(@start_fnty, {})
        \\@start = fn(@start_fnty, {
        \\  %0 = call(@s, [])
        \\})
        \\@0 = str("_start")
        \\@1 = export(@0, "start")
    , &[_][]const u8{":4:9: error: unable to call function with naked calling convention"});

    // TODO: re-enable these tests.
    // https://github.com/ziglang/zig/issues/1364

    //  ctx.addError("Export same symbol twice", linux_x64, .Zig,
    //      \\export fn entry() void {}
    //      \\export fn entry() void {}
    //  , &[_][]const u8{":2:1: error: exported symbol collision"});

    //    ctx.addError("Missing function name", linux_x64, .Zig,
    //        \\fn() void {}
    //    , &[_][]const u8{":1:3: error: missing function name"});
    //ctx.testCompileError(
    //    \\comptime {
    //    \\    return;
    //    \\}
    //, "1.zig", 2, 5, "return expression outside function definition");

    //ctx.testCompileError(
    //    \\export fn entry() void {
    //    \\    defer return;
    //    \\}
    //, "1.zig", 2, 11, "cannot return from defer expression");

    //ctx.testCompileError(
    //    \\export fn entry() c_int {
    //    \\    return 36893488147419103232;
    //    \\}
    //, "1.zig", 2, 12, "integer value '36893488147419103232' cannot be stored in type 'c_int'");

    //ctx.testCompileError(
    //    \\comptime {
    //    \\    var a: *align(4) align(4) i32 = 0;
    //    \\}
    //, "1.zig", 2, 22, "Extra align qualifier");

    //ctx.testCompileError(
    //    \\comptime {
    //    \\    var b: *const const i32 = 0;
    //    \\}
    //, "1.zig", 2, 19, "Extra align qualifier");

    //ctx.testCompileError(
    //    \\comptime {
    //    \\    var c: *volatile volatile i32 = 0;
    //    \\}
    //, "1.zig", 2, 22, "Extra align qualifier");

    //ctx.testCompileError(
    //    \\comptime {
    //    \\    var d: *allowzero allowzero i32 = 0;
    //    \\}
    //, "1.zig", 2, 23, "Extra align qualifier");
}
