const arr = [_]i32{ 1, 2, 3 };
const idx: usize = @intCast(a);
if (a > 100) return error.TooBig;
return arr[idx];
