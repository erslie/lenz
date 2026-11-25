const std = @import("std");
const cpu = @import("arch/cpu.zig");
const timer = @import("arch/timer.zig");
const exception = @import("arch/exception.zig");
const trace = @import("trace.zig");
const symbols = @import("symbols.zig");
const uart = @import("uart.zig");
const mmu = @import("arch/mmu.zig");

pub const State = enum { ready, sleeping, dead };

pub const Task = struct {
    id: u32,
    name: []const u8,
    state: State = .ready,
    sp: usize = 0,
    stack: []u8,
    wake_tick: u64 = 0,
    switches: u64 = 0,
    entry: *const fn (arg: usize) void,
    arg: usize = 0,
    last_run_tick: u64 = 0,
    watchdog_reported: bool = false,
};

const PATTERN: u8 = 0x5a;

// "LENZCANY"
const CANNARY: u64 = 0x4c454e5a_43414e59;

const max_tasks = 16;

var tasks: [max_tasks]Task = undefined;
var count: usize = 0;
var current: usize = 0;
var gpa: std.mem.Allocator = undefined;

// AAPCS64: "Registers r19-r29 and SP are Callee-saved."
// https://github.com/ARM-software/abi-aa/blob/main/aapcs64/aapcs64.rst
comptime {
    asm (
        \\.section .text, "ax"
        \\.global switchContext
        \\switchContext:
        \\      sub     sp, sp, #96
        \\      stp     x19, x20, [sp, #0]
        \\      stp     x21, x22, [sp, #16]
        \\      stp     x23, x24, [sp, #32]
        \\      stp     x25, x26, [sp, #48]
        \\      stp     x27, x28, [sp, #64]
        \\      stp     x29, x30, [sp, #80]
        \\      mov     x9, sp
        \\      str     x9, [x0]
        \\      mov     sp, x1
        \\      ldp     x19, x20, [sp, #0]
        \\      ldp     x21, x22, [sp, #16]
        \\      ldp     x23, x24, [sp, #32]
        \\      ldp     x25, x26, [sp, #48]
        \\      ldp     x27, x28, [sp, #64]
        \\      ldp     x29, x30, [sp, #80]
        \\      add     sp, sp, #96
        \\      ret
        \\
        \\.global taskTrampoline
        \\taskTrampoline:
        \\      mov     x0, x19
        \\      bl      taskStart
        \\      brk     #0xdead
    );
}
extern fn switchContext(old_sp: *usize, new_sp: usize) callconv(.c) void;
extern fn taskTrampoline() callconv(.c) void;

export fn taskStart(t: *Task) callconv(.c) noreturn {
    cpu.enableIrq();
    t.entry(t.arg);
    t.state = .dead;
    std.log.info("task '{s}' ended", .{t.name});
    yield();
    unreachable;
}

/// Register the boot flow (kmain) as task 0
pub fn init(allocator: std.mem.Allocator) void {
    gpa = allocator;
    tasks[0] = .{ .id = 0, .name = "boot", .stack = &.{}, .entry = undefined };
    count = 1;
    current = 0;
    timer.on_tick = &watchdog;
}

pub fn spawn(name: []const u8, entry: *const fn (usize) void, arg: usize, stack_size: usize) !*Task {
    if (count == max_tasks) return error.TooManyTasks;

    // Put a 4KB guard page below the stack and remove it from the map.
    // On overflow it faults here, before breaking other tasks' stacks or the heap.
    // (Before freeing this memory, put the page back with setPage first. The heap paints memory on free, so if it's still removed, that faluts)
    const region = try gpa.alignedAlloc(u8, .fromByteUnits(4096), 4096 + stack_size);
    mmu.addGuard(@intFromPtr(region.ptr), name);
    const stack = region[4096..];
    @memset(stack, PATTERN);
    std.mem.writeInt(u64, stack[0..8], CANNARY, .little);
    const t = &tasks[count];
    t.* = .{ .id = @intCast(count), .name = name, .stack = stack, .entry = entry, .arg = arg };

    // Prepare the 96 bytes switchContext pops at the very top of the stack
    const top = @intFromPtr(stack.ptr) + stack.len;
    const frame: *[12]u64 = @ptrFromInt(top - 96);
    frame.* = @splat(0);
    // x19
    frame[0] = @intFromPtr(t);
    // x29 = 0: the backtrace ends here
    frame[10] = 0;
    // x30: target of the first ret
    frame[11] = @intFromPtr(&taskTrampoline);
    t.sp = top - 96;
    count += 1;
    std.log.info("created task {d} '{s}' (stack {d} bytes @0x{x})", .{ t.id, name, stack_size, @intFromPtr(stack.ptr) });

    return t;
}

fn checkCanary(t: *Task) void {
    if (t.stack.len == 0) return;
    if (std.mem.readInt(u64, t.stack[0..8], .little) != CANNARY)
        std.debug.panic("the bottom of the stack of task '{s}' is corrupted (possible overflow)", .{t.name});
}

pub fn yield() void {
    const was_on = cpu.irqEnabled();
    cpu.disableIrq();
    defer if (was_on) cpu.enableIrq();

    const prev = current;
    var next = prev;
    while (true) {
        for (tasks[0..count]) |*t| {
            if (t.state == .sleeping and timer.tick_count >= t.wake_tick) t.state = .ready;
        }
        var i: usize = 1;
        while (i <= count) : (i += 1) {
            const cand = (prev + i) % count;
            if (tasks[cand].state == .ready) {
                next = cand;
                break;
            }
        } else {
            // Nobady can run: wait for an interrupt
            // (wfi wakes up once an interrupt is "pending", even while masked)
            cpu.wfi();
            // Take pending interrupts here
            cpu.enableIrq();
            cpu.disableIrq();
            continue;
        }
        break;
    }

    if (next == prev) {
        const c = currentTask();
        c.last_run_tick = timer.tick_count;
        c.watchdog_reported = false;
        return;
    }

    checkCanary(&tasks[prev]);
    tasks[next].switches += 1;
    tasks[next].last_run_tick = timer.tick_count;
    tasks[next].watchdog_reported = false;
    trace.record(.task_switch, tasks[prev].id, tasks[next].id, tasks[next].name);
    current = next;
    switchContext(&tasks[prev].sp, tasks[next].sp);
}

pub fn sleepTicks(n: u64) void {
    tasks[current].wake_tick = timer.tick_count + n;
    tasks[current].state = .sleeping;
    yield();
}

pub fn sleepMs(ms: u64) void {
    sleepTicks(@max(1, ms * timer.hz / 1000));
}

pub fn currentTask() *Task {
    return &tasks[current];
}

fn watchdog() void {
    const t = &tasks[current];
    if (t.state == .ready and !t.watchdog_reported and timer.tick_count - t.last_run_tick > timer.hz) {
        t.watchdog_reported = true;
        const f = exception.current_irq_frame orelse return;
        uart.print("\n[watchdog] task '{s}' has not given up the CPU for over 1 second. Currently at: ", .{t.name});
        symbols.print(&uart.writer, f.elr);
        uart.write("\n");
    }
}

// Count how much of the stack was never written (pattern still there)
fn unusedStack(t: *const Task) usize {
    var n: usize = 8;
    while (n < t.stack.len and t.stack[n] == PATTERN) n += 1;
    return n - 8;
}

// List of created tasks (used by the screen panel)
pub fn list() []const Task {
    return tasks[0..count];
}

// Peak stack usage (bytes)
pub fn stackUsed(t: *const Task) usize {
    return t.stack.len - 8 - unusedStack(t);
}

pub fn dump(w: *std.Io.Writer) void {
    w.print("   ID name         state       switch     max stack used\n", .{}) catch {};
    for (tasks[0..count], 0..) |*t, i| {
        w.print("   {d:>2} {s:<12} {s:<9} {d:>8}     ", .{ t.id, t.name, @tagName(t.state), t.switches }) catch {};
        if (t.stack.len == 0) {
            w.print("(boot stack)", .{}) catch {};
        } else {
            const used = t.stack.len - 8 - unusedStack(t);
            w.print("{d} / {d} bytes", .{ used, t.stack.len }) catch {};
        }
        w.print("{s}\n", .{if (i == current) " <- running" else ""}) catch {};
    }
}
