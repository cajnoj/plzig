CREATE FUNCTION t02_primes_plpgsql(n int) RETURNS int LANGUAGE plpgsql IMMUTABLE STRICT AS $$
DECLARE
    c int := 0;
    d int;
    is_prime boolean;
BEGIN
    FOR i IN 2..n LOOP
        is_prime := true;
        d := 2;
        WHILE d * d <= i LOOP
            IF i % d = 0 THEN
                is_prime := false;
                EXIT;
            END IF;
            d := d + 1;
        END LOOP;
        IF is_prime THEN
            c := c + 1;
        END IF;
    END LOOP;
    RETURN c;
END
$$;

-- sum of escape iterations over one row (ci = 0.35) of the Mandelbrot set
CREATE FUNCTION t02_mandel_plpgsql(w int, maxiter int) RETURNS bigint LANGUAGE plpgsql IMMUTABLE STRICT AS $$
DECLARE
    total bigint := 0;
    cr float8;
    ci float8 := 0.35;
    zr float8;
    zi float8;
    t float8;
    k int;
BEGIN
    FOR i IN 0..w - 1 LOOP
        cr := -2.0::float8 + (2.5::float8 * i) / w;
        zr := 0;
        zi := 0;
        k := 0;
        WHILE k < maxiter AND zr * zr + zi * zi <= 4.0::float8 LOOP
            t := zr * zr - zi * zi + cr;
            zi := 2.0::float8 * zr * zi + ci;
            zr := t;
            k := k + 1;
        END LOOP;
        total := total + k;
    END LOOP;
    RETURN total;
END
$$;
