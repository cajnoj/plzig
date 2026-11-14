CREATE FUNCTION t09_plpgsql(n int) RETURNS int LANGUAGE plpgsql VOLATILE STRICT AS $$
BEGIN
    FOR i IN 1..n LOOP
        INSERT INTO bench_t9 VALUES (i, i);
    END LOOP;
    FOR i IN 1..n LOOP
        UPDATE bench_t9 SET v = v + 1 WHERE id = i;
    END LOOP;
    RETURN n;
END
$$;
