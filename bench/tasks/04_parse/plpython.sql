CREATE FUNCTION t04_plpython(line text) RETURNS text LANGUAGE plpython3u IMMUTABLE STRICT AS $$
ident = SD.get('ident')
if ident is None:
    import re
    ident = SD['ident'] = re.compile(r'[a-z_][a-z0-9_]{0,62}').fullmatch
out = []
for f in line.split(','):
    f = f.strip(' ').lower()
    out.append(f if ident(f) else '?')
return ','.join(out)
$$;
