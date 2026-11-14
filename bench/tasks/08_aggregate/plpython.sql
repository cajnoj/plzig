-- A cursor read in batches (plpy.execute would materialise every row as a
-- Python dict first).
CREATE FUNCTION t08_plpython() RETURNS text LANGUAGE plpython3u STABLE AS $$
plan = SD.get('plan')
if plan is None:
    plan = SD['plan'] = plpy.prepare("SELECT k, v FROM bench_big")
s = c = 0
cur = plpy.cursor(plan)
while True:
    rows = cur.fetch(1000)
    if not rows:
        break
    for r in rows:
        if r['k'] % 3 == 0:
            s += r['v']
    c += len(rows)
return f'{s}/{c}'
$$;
