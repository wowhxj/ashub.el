// One explicitly-authorized live probe. Not part of the automatic regression gate.
// A private loopback relay forwards at most TWO real model requests, strips all
// system context to a fixed test prompt, and caps each response at 256 tokens.
import fs from 'node:fs';
import path from 'node:path';
import os from 'node:os';
import http from 'node:http';
import net from 'node:net';
import {spawn, execFileSync} from 'node:child_process';
import {fileURLToPath} from 'node:url';
import {Readable} from 'node:stream';
const hub = fileURLToPath(new URL('../', import.meta.url));
const pi = path.join(path.dirname(hub.slice(0,-1)), 'emacs-pi');
const md = '/Users/randolph/.emacs.d.default/elpa/markdown-mode-20261022.55';
const approval = path.join(pi,'dev/live-approval.mjs');
const childScript = path.join(pi,'dev/live-model-child.el');
const ledgerDir = path.join(hub,'.ralph/artifacts/live-pi');
fs.mkdirSync(ledgerDir,{recursive:true,mode:0o700});
const ledger = path.join(ledgerDir,'authorization-used.json');
if (process.env.PI_LIVE_APPROVED !== '1') throw Error('Explicit current user approval required');
if (fs.existsSync(ledger)) throw Error('This authorization has already been claimed; never rerun automatically');
const auth = JSON.parse(fs.readFileSync(path.join(os.homedir(),'.pi/agent/auth.json'),'utf8')).deepseek;
if (auth?.type!=='api_key'||typeof auth.key!=='string'||!auth.key||/^[!$]/.test(auth.key)) throw Error('Literal DeepSeek API key unavailable; no request sent');
const root=fs.realpathSync(fs.mkdtempSync('/tmp/pi-live-'));fs.chmodSync(root,0o700);
const work=path.join(root,'work'),agent=path.join(root,'agent');fs.mkdirSync(work);fs.mkdirSync(agent,{mode:0o700});
const result={root,authorizedMaxRequests:2,maxOutputTokensPerRequest:256,forwarded:0,blocked:0,requests:[],status:'starting'};
const save=()=>fs.writeFileSync(ledger,JSON.stringify(result,null,2)+'\n',{mode:0o600});
fs.writeFileSync(ledger,JSON.stringify(result)+'\n',{flag:'wx',mode:0o600});
const server=http.createServer(async(req,res)=>{
 if(req.method!=='POST'||req.url!=='/v1/chat/completions'){res.writeHead(404);res.end();return;}
 let bytes=0,chunks=[];
 for await(const chunk of req){bytes+=chunk.length;if(bytes>128*1024){res.writeHead(413);res.end();return;}chunks.push(chunk);}
 if(result.forwarded>=2){result.blocked++;save();res.writeHead(429,{'content-type':'application/json'});res.end('{"error":{"message":"Explicit live-test request limit reached"}}');return;}
 const body=JSON.parse(Buffer.concat(chunks));
 const messages=[{role:'system',content:'You are in an isolated lifecycle test. Perform only the exact authorized bash marker command, then reply OK. Never access other files.'},...(body.messages||[]).filter(m=>m.role!=='system'&&m.role!=='developer')];
 const count=++result.forwarded;
 const info={number:count,hasSteering:JSON.stringify(messages).includes('STEER_LIVE_PROBE'),roles:messages.map(m=>m.role),status:null};result.requests.push(info);save();
 const payload={model:'deepseek-chat',messages,stream:true,max_tokens:256,temperature:0,
  ...(count===1?{tools:body.tools,tool_choice:{type:'function',function:{name:'bash'}}}:{tool_choice:'none'})};
 try{
  const response=await fetch('https://api.deepseek.com/chat/completions',{method:'POST',redirect:'error',signal:AbortSignal.timeout(90000),headers:{'content-type':'application/json',authorization:`Bearer ${auth.key}`},body:JSON.stringify(payload)});
  info.status=response.status;save();
  res.writeHead(response.status,{'content-type':response.headers.get('content-type')||'text/event-stream'});
  if(!response.ok){await response.body?.cancel();res.end('{"error":{"message":"Upstream rejected the isolated probe; details omitted"}}');return;}
  Readable.fromWeb(response.body).pipe(res);
 }catch{info.status='transport-error';save();if(!res.headersSent)res.writeHead(502);res.end();}
});
await new Promise(r=>server.listen(0,'127.0.0.1',r));
fs.writeFileSync(path.join(agent,'models.json'),JSON.stringify({providers:{'lifecycle-live':{api:'openai-completions',baseUrl:`http://127.0.0.1:${server.address().port}/v1`,apiKey:'test-relay-only',models:[{id:'deepseek-chat',name:'Isolated live test',reasoning:false,input:['text'],contextWindow:32768,maxTokens:256,compat:{supportsStore:false,supportsDeveloperRole:false,maxTokensField:'max_tokens'}}]}}}),{mode:0o600});
fs.writeFileSync(path.join(agent,'settings.json'),JSON.stringify({defaultProvider:'lifecycle-live',defaultModel:'deepseek-chat',defaultThinkingLevel:'off',compaction:{enabled:false}}),{mode:0o600});
fs.writeFileSync(path.join(root,'history.jsonl'),JSON.stringify({type:'session',version:3,id:'isolated-live-pi',cwd:work,timestamp:new Date().toISOString()})+'\n',{mode:0o600});
const executable=execFileSync('/bin/sh',['-c','command -v pi'],{encoding:'utf8'}).trim();
const command=`printf 'LIVE\\n' >> '${path.join(work,'marker')}'`;
const env={PATH:process.env.PATH,HOME:root,TMPDIR:'/tmp',LANG:'en_US.UTF-8',SHELL:'/bin/sh',PI_CODING_AGENT_DIR:agent,PI_LIVE_ROOT:root,PI_LIVE_EXECUTABLE:executable,PI_LIVE_EXTENSION:approval,PI_LIVE_PROMPT:`Use bash to run exactly this command once: ${command} . Wait for its test confirmation. After it succeeds reply exactly OK. Do not issue any other command.`};
const sleep=ms=>new Promise(r=>setTimeout(r,ms));
async function wait(fn,ms=100000){const end=Date.now()+ms;while(Date.now()<end){if(fn())return;await sleep(30);}throw Error('Live probe deadline exceeded');}
function client(mode){const out=fs.openSync(path.join(root,mode+'.log'),'w',0o600);const c=spawn('emacs',['--batch','-Q','-L',pi,'-L',md,'--eval','(setq load-prefer-newer t)','-l',childScript],{cwd:work,env:{...env,PI_LIVE_MODE:mode},stdio:['ignore',out,out]});fs.closeSync(out);return c;}
let first,second;
async function finishOwnFixture(){
 const runtime=path.join(root,'runtime');if(!fs.existsSync(runtime))return;
 for(const name of fs.readdirSync(runtime).filter(n=>/^[a-f0-9]{32}$/.test(n))){
  const dir=path.join(runtime,name),state=JSON.parse(fs.readFileSync(path.join(dir,'state.json')));
  if(state.cwd!==work||!['running','stopping'].includes(state.status))continue;
  await new Promise((resolve,reject)=>{let pending='',ok=false;const s=net.createConnection(path.join(dir,'rpc.sock'));const t=setTimeout(()=>{s.destroy();reject(Error('Owned live-fixture finish unconfirmed'));},15000);s.on('error',reject);s.on('close',()=>{clearTimeout(t);ok?resolve():reject(Error('No confirmed finish'));});s.on('connect',()=>s.write(JSON.stringify({op:'attach',version:1,token:state.token})+'\n'));s.on('data',b=>{pending+=b;let i;while((i=pending.indexOf('\n'))>=0){const v=JSON.parse(pending.slice(0,i));pending=pending.slice(i+1);if(v.op==='ready')s.write(JSON.stringify({op:'rpc',request:{type:'emacs_pi_finish',id:'live-test-cleanup'}})+'\n');if(v.record?.command==='emacs_pi_finish'&&v.record.success)ok=true;}});});
 }
}
try{
 first=client('start');
 await wait(()=>{if(first.exitCode!==null)throw Error('Start client failed; see private test log');return fs.existsSync(path.join(root,'armed.json'));});
 if(result.forwarded!==1||fs.existsSync(path.join(work,'marker')))throw Error('Unexpected work/call before approval');
 first.kill('SIGKILL');await wait(()=>first.signalCode!==null,5000);await sleep(150);
 if(fs.existsSync(path.join(work,'marker')))throw Error('Unapproved command ran after Emacs SIGKILL');
 second=client('resume');await wait(()=>second.exitCode!==null||second.signalCode!==null,100000);
 if(second.exitCode!==0)throw Error('Resume client failed; see private test log');
 const verified=JSON.parse(fs.readFileSync(path.join(root,'verified.json')));
 if(result.forwarded!==2||result.requests.some(r=>r.status!==200)||!result.requests[1].hasSteering||fs.readFileSync(path.join(work,'marker'),'utf8')!=='LIVE\n'||fs.readFileSync(path.join(root,'tool-approved'),'utf8')!=='approved\n')throw Error('Live authority/call/queue/marker mismatch');
 Object.assign(result,verified,{status:'passed'});
}catch(error){result.status='failed';result.error=error.message;process.exitCode=1;}
finally{
 for(const c of [first,second])if(c&&c.exitCode===null&&c.signalCode===null)c.kill('SIGKILL');
 await sleep(150);try{await finishOwnFixture();result.cleanup='confirmed';}catch(error){result.cleanup=error.message;process.exitCode=1;}
 save();server.closeAllConnections();await new Promise(r=>server.close(r));
 console.log(JSON.stringify(result,null,2));
}
