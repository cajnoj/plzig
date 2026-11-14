CREATE FUNCTION t09_plpython(n int) RETURNS int LANGUAGE plpython3u VOLATILE STRICT AS $$
if 'ins' not in SD:
    SD['ins'] = plpy.prepare("INSERT INTO bench_t9 VALUES ($1, $2)", ["int4", "int4"])
    SD['upd'] = plpy.prepare("UPDATE bench_t9 SET v = v + 1 WHERE id = $1", ["int4"])
ins, upd = SD['ins'], SD['upd']
for i in range(1, n + 1):
    plpy.execute(ins, [i, i])
for i in range(1, n + 1):
    plpy.execute(upd, [i])
return n
$$;
