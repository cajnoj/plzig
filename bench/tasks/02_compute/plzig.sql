CREATE FUNCTION t02_primes_plzig(n int) RETURNS int LANGUAGE plzig IMMUTABLE STRICT AS $$
    var c: i32 = 0;
    var i: u32 = 2;
    while (i <= @as(u32, @intCast(n))) : (i += 1) {
        var d: u32 = 2;
        const is_prime = while (d * d <= i) : (d += 1) {
            if (i % d == 0) break false;
        } else true;
        if (is_prime) c += 1;
    }
    return c;
$$;

CREATE FUNCTION t02_mandel_plzig(w int, maxiter int) RETURNS bigint LANGUAGE plzig IMMUTABLE STRICT AS $$
    var total: i64 = 0;
    const ci: f64 = 0.35;
    const wf: f64 = @floatFromInt(w);
    var i: i32 = 0;
    while (i < w) : (i += 1) {
        const cr = -2.0 + (2.5 * @as(f64, @floatFromInt(i))) / wf;
        var zr: f64 = 0;
        var zi: f64 = 0;
        var k: i32 = 0;
        while (k < maxiter and zr * zr + zi * zi <= 4.0) : (k += 1) {
            const t = zr * zr - zi * zi + cr;
            zi = 2.0 * zr * zi + ci;
            zr = t;
        }
        total += k;
    }
    return total;
$$;
