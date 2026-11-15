const fs=require('node:fs'),cp=require('node:child_process'),ts=require('typescript');
const files=fs.readdirSync('js').filter(f=>f.endsWith('.js')).map(f=>'js/'+f).concat('sw.js');
for(const file of files)cp.execFileSync(process.execPath,['--check',file],{stdio:'pipe'});
function walk(dir){return fs.readdirSync(dir,{withFileTypes:true}).flatMap(e=>e.isDirectory()?walk(dir+'/'+e.name):[dir+'/'+e.name]);}
let count=0;for(const file of walk('supabase/functions').filter(p=>p.endsWith('.ts'))){const result=ts.transpileModule(fs.readFileSync(file,'utf8'),{fileName:file,reportDiagnostics:true,compilerOptions:{target:ts.ScriptTarget.ES2022,module:ts.ModuleKind.ESNext}});const errors=result.diagnostics.filter(d=>d.category===ts.DiagnosticCategory.Error);if(errors.length)throw Error(file+': '+errors.map(d=>ts.flattenDiagnosticMessageText(d.messageText,' ')).join('\n'));count++;}
console.log(`${files.length} JavaScript files parsed; ${count} Edge Function TypeScript files transpiled.`);
