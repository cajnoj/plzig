const s = try std.fmt.allocPrint(plzig.allocator, "value {d}", .{a});
plzig.notice("{s}", .{s});
return @intCast(s.len);
