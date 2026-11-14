CREATE FUNCTION t07_plpython(n int) RETURNS bigint LANGUAGE plpython3u STABLE STRICT AS $$
plan = SD.get('plan')
if plan is None:
    plan = SD['plan'] = plpy.prepare("SELECT v FROM bench_kv WHERE k = $1", ["int4"])
s = 0
for i in range(1, n + 1):
    s += plpy.execute(plan, [i * 7919 % 100000 + 1])[0]['v']
return s
$$;
