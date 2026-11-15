#!/usr/bin/env python3
"""Disposable PostgreSQL checks. Requires Docker; never connects to production."""
from pathlib import Path
import os,re,subprocess,time
root=Path(__file__).resolve().parents[1]
logs=root/'work'/'test-results';logs.mkdir(parents=True,exist_ok=True)
name='uniguard-regression-'+str(os.getpid())
def sql(source,label):
    result=subprocess.run(['docker','exec','-i',name,'psql','-U','postgres','-v','ON_ERROR_STOP=1'],input=source,text=True,capture_output=True)
    (logs/(label+'.log')).write_text(result.stdout+result.stderr)
    if result.returncode: raise RuntimeError(label+' failed:\n'+result.stderr[-3000:])
    return result.stdout
try:
    subprocess.run(['docker','run','--rm','-d','--name',name,'-e','POSTGRES_PASSWORD=isolated-regression-only','postgres:17'],check=True,capture_output=True)
    for _ in range(100):
        ready=subprocess.run(['docker','exec',name,'pg_isready','-U','postgres'],capture_output=True)
        startup=subprocess.run(['docker','logs',name],capture_output=True,text=True)
        if ready.returncode==0 and 'init process complete; ready for start up' in (startup.stdout+startup.stderr):break
        time.sleep(.3)
    else:raise RuntimeError('Test database did not become ready')
    sql((root/'tests/bootstrap.sql').read_text(),'bootstrap')
    sql('create extension if not exists pg_trgm;','baseline-extension')
    baseline=[];upgrades=[]
    for path in sorted((root/'migrations').glob('*.sql')):
        number=int(path.name[:3])
        if number==0:continue
        if number>60:upgrades.append(path);continue
        if number==43:
            # 043 requires its configured owner account, which must exist first.
            email=re.search(r"v_email constant text := '([^']+)'",path.read_text())[1]
            sql("insert into auth.users(id,email) values(gen_random_uuid(),'"+email.replace("'","''")+"');",'owner-fixture')
        sql(path.read_text(),path.stem)
    signature_query="select n.nspname||'.'||p.proname||'('||pg_get_function_identity_arguments(p.oid)||')->'||pg_get_function_result(p.oid) from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='public' order by 1;"
    before=sql(signature_query,'signatures-before')
    for turn in range(2):
        for path in upgrades:sql(path.read_text(),path.stem+'-pass'+str(turn+1))
    after=sql(signature_query,'signatures-after')
    # Ignore psql header/footer and retain concrete function records.
    original={line.strip() for line in before.splitlines() if line.strip().startswith('public.')}
    current={line.strip() for line in after.splitlines() if line.strip().startswith('public.')}
    if original-current:raise RuntimeError('An existing function signature disappeared: '+str(original-current))
    central=sql("select count(*) from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='public' and prosrc ilike '%insert into public.notifications%' and proname<>'ug_notify';",'central-insert-audit')
    if re.search(r'\n\s*0\s*\n',central) is None:raise RuntimeError('A legacy function still inserts notifications directly')
    print('PASS: 001–060 baseline, then 061–067 applied twice; existing RPC signatures retained.')
    for filename in ['database.sql','push-database.sql']:
        sql((root/'tests'/filename).read_text(),filename.replace('.sql',''))
        contents=(logs/(filename.replace('.sql','')+'.log')).read_text()
        print('PASS:',filename,contents.count('NOTICE:  PASS:'),'checks')
    print('Transport, auth and storage APIs are test doubles; real device acceptance is documented separately.')
    print('Logs:',logs)
finally:
    subprocess.run(['docker','rm','-f',name],capture_output=True)
