//! Allocation-bounded structural admission for untrusted MCP JSON.

const std = @import("std");

pub const Limits = struct {
    max_depth: usize,
    max_nodes: usize,
    max_container_entries: usize,
    max_work_units: usize,
};

pub const Admission = enum {
    valid,
    invalid_json,
    resource_limit,
    out_of_memory,
};

const ContainerKind = enum { object, array };

const ContainerState = struct {
    kind: ContainerKind,
    entries: usize = 0,
    /// Object keys and values alternate. Arrays ignore this field.
    expects_key: bool = true,
};

/// Validate JSON grammar and structural budgets before building a dynamic
/// tree. Scanner partial tokens are lexical fragments, not extra JSON values.
pub fn admit(
    allocator: std.mem.Allocator,
    encoded: []const u8,
    limits: Limits,
) Admission {
    var scanner = std.json.Scanner.initCompleteInput(allocator, encoded);
    defer scanner.deinit();
    var containers = std.ArrayList(ContainerState).empty;
    defer containers.deinit(allocator);
    var nodes: usize = 0;
    var work: usize = 0;
    var root_values: u8 = 0;

    while (true) {
        const token = scanner.next() catch |err| return switch (err) {
            error.OutOfMemory => .out_of_memory,
            else => .invalid_json,
        };
        if (work == limits.max_work_units) return .resource_limit;
        work += 1;

        switch (token) {
            .end_of_document => return if (root_values == 1 and containers.items.len == 0)
                .valid
            else
                .invalid_json,
            .object_begin, .array_begin => {
                if (!admitValue(&containers, &root_values, &nodes, limits))
                    return .resource_limit;
                if (containers.items.len == limits.max_depth)
                    return .resource_limit;
                containers.append(allocator, .{
                    .kind = if (token == .object_begin) .object else .array,
                }) catch return .out_of_memory;
            },
            .object_end => {
                if (containers.items.len == 0) return .invalid_json;
                const current = containers.items[containers.items.len - 1];
                if (current.kind != .object or !current.expects_key)
                    return .invalid_json;
                _ = containers.pop();
            },
            .array_end => {
                if (containers.items.len == 0 or
                    containers.items[containers.items.len - 1].kind != .array)
                    return .invalid_json;
                _ = containers.pop();
            },
            .string => {
                if (containers.items.len != 0) {
                    const current = &containers.items[containers.items.len - 1];
                    if (current.kind == .object and current.expects_key) {
                        if (current.entries == limits.max_container_entries)
                            return .resource_limit;
                        current.entries += 1;
                        current.expects_key = false;
                        continue;
                    }
                }
                if (!admitValue(&containers, &root_values, &nodes, limits))
                    return .resource_limit;
            },
            .number, .true, .false, .null => {
                if (!admitValue(&containers, &root_values, &nodes, limits))
                    return .resource_limit;
            },
            .partial_number,
            .partial_string,
            .partial_string_escaped_1,
            .partial_string_escaped_2,
            .partial_string_escaped_3,
            .partial_string_escaped_4,
            => {},
            // `Scanner.next` does not allocate complete tokens. Treat a future
            // contract change as invalid input rather than counting it twice.
            .allocated_number, .allocated_string => return .invalid_json,
        }
    }
}

fn admitValue(
    containers: *std.ArrayList(ContainerState),
    root_values: *u8,
    nodes: *usize,
    limits: Limits,
) bool {
    if (nodes.* == limits.max_nodes) return false;
    nodes.* += 1;
    if (containers.items.len == 0) {
        if (root_values.* != 0) return false;
        root_values.* = 1;
        return true;
    }
    const current = &containers.items[containers.items.len - 1];
    switch (current.kind) {
        .array => {
            if (current.entries == limits.max_container_entries) return false;
            current.entries += 1;
        },
        .object => {
            if (current.expects_key) return false;
            current.expects_key = true;
        },
    }
    return true;
}
