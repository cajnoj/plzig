const n: usize = @intCast(@mod(a, 1 << 20));
const b = try plzig.allocator.alloc(u8, n * 8);
@memset(b, 1);
var sum: i32 = 0;
for (b) |x| sum +%= x;
return sum;
