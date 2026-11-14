CREATE FUNCTION t02_primes_plpython(n int) RETURNS int LANGUAGE plpython3u IMMUTABLE STRICT AS $$
c = 0
for i in range(2, n + 1):
    d = 2
    while d * d <= i:
        if i % d == 0:
            break
        d += 1
    else:
        c += 1
return c
$$;

CREATE FUNCTION t02_mandel_plpython(w int, maxiter int) RETURNS bigint LANGUAGE plpython3u IMMUTABLE STRICT AS $$
total = 0
ci = 0.35
for i in range(w):
    cr = -2.0 + (2.5 * i) / w
    zr = zi = 0.0
    k = 0
    while k < maxiter and zr * zr + zi * zi <= 4.0:
        zr, zi = zr * zr - zi * zi + cr, 2.0 * zr * zi + ci
        k += 1
    total += k
return total
$$;
