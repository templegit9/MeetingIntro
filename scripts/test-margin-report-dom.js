const fs=require('fs'),vm=require('vm');
const html=fs.readFileSync(process.argv[2],'utf8');
const payload=html.match(/<script id="data" type="application\/json">([\s\S]*?)<\/script>/)[1];
const script=html.match(/<script>([\s\S]*?)<\/script>/)[1];
class Node {constructor(tag){this.tag=tag;this.children=[];this.value='';this.textContent='';this.className=''}append(...children){this.children.push(...children)}replaceChildren(...children){this.children=children}querySelector(){return this.body??=new Node('tbody')}addEventListener(){}scrollIntoView(){}}
const nodes=new Map();const document={getElementById(id){if(!nodes.has(id))nodes.set(id,new Node(id));return nodes.get(id)},createElement:t=>new Node(t),createTextNode:t=>({textContent:t})};document.getElementById('data').textContent=payload;
const context={document,Intl,Date,JSON,Object,Math,String,Number,window:{scrollTo(){}}};vm.createContext(context);vm.runInContext(script,context);
const data=JSON.parse(payload),latest=data.runs.at(-1);
if(document.getElementById('headline').textContent!==latest.status)throw Error('Wrong latest run');
const nums=document.getElementById('stats').children.map(n=>Number(n.children[0].textContent));
if(nums.reduce((a,b)=>a+b,0)!==latest.rows.length)throw Error('Counts do not add up');
const rows=document.getElementById('categoryTable').body.children;
if(rows.reduce((n,row)=>n+row.children.slice(1).reduce((v,c)=>v+Number(c.textContent),0),0)!==latest.rows.length)throw Error('Category accounting mismatch');
document.getElementById('status').value='fail';vm.runInContext('renderCases()',context);
if(document.getElementById('cases').children.length!==latest.counts.fail && latest.counts.fail)throw Error('Failure filter');
document.getElementById('run').value=0;vm.runInContext('render()',context);
if(document.getElementById('headline').textContent!==data.runs[0].status)throw Error('History selector');
console.log('Report DOM logic passed: latest run, count reconciliation, category totals, failure filter, history selector.');
