#!/bin/bash
# Interactive contact sheet: marquee drag-select + one-click batch assign to a case label.
# Reuses thumbnails already in thumbs/. Emits an HTML app that exports mapping.json.
set -euo pipefail
cd "$(dirname "$0")"

# Build a JS array literal: {num, file, t} sorted by capture time (mtime preserved from phone).
DATA=$(stat -f "%m	%N" IMG_*.HEIC | sort -n | while IFS=$'\t' read -r epoch name; do
  base="${name%.HEIC}"; num="${base#IMG_}"
  t=$(date -r "$epoch" "+%a %H:%M:%S")
  printf '{"num":"%s","file":"%s","epoch":%s,"t":"%s"},' "$num" "$base" "$epoch" "$t"
done)

HTML=contact_sheet.html
cat > "$HTML" <<HEAD
<!doctype html><html><head><meta charset="utf-8">
<title>Recycled Sound — photo sort 2026-05-20</title>
<style>
  *{box-sizing:border-box}
  body{font-family:-apple-system,system-ui,sans-serif;background:#111;color:#eee;margin:0;padding:0}
  header{position:sticky;top:0;z-index:50;background:#1a1a1a;border-bottom:1px solid #333;padding:10px 16px}
  h1{font-size:16px;margin:0 0 6px}
  .hint{color:#9ad;font-size:12px;margin:0 0 8px}
  .palette{display:flex;flex-wrap:wrap;gap:6px;align-items:center}
  .palette button{border:0;border-radius:6px;padding:6px 10px;font-size:13px;cursor:pointer;color:#111;font-weight:600}
  .palette .act{background:#2a2a2a;color:#eee;border:1px solid #444}
  #status{font-size:12px;color:#bbb;margin-left:auto}
  .grid{display:flex;flex-wrap:wrap;gap:8px;padding:16px;position:relative;user-select:none}
  .cell{width:170px;background:#1c1c1c;border-radius:8px;padding:6px;text-align:center;border:3px solid transparent;position:relative}
  .cell img{width:156px;height:auto;border-radius:4px;display:block;pointer-events:none}
  .cell.sel{outline:3px solid #4af;outline-offset:1px}
  .cap{font-size:12px;margin-top:4px}.num{font-weight:700;color:#fff}.time{color:#888}
  .cell.del{opacity:.28;filter:grayscale(1)}.cell.del .num{text-decoration:line-through;color:#e44}
  .cell.done{display:none}
  body.reveal .cell.done{display:block;opacity:.5}
  body.reveal .cell.done.del{opacity:.28}
  .tag{position:absolute;top:8px;left:8px;font-size:11px;font-weight:700;padding:1px 6px;border-radius:4px;color:#111}
  .sep{flex-basis:100%;height:0;border-top:2px dashed #e55;margin:14px 0 6px;position:relative}
  .sep span{position:absolute;top:-10px;left:0;background:#111;color:#e55;font-size:12px;padding:0 8px}
  #marquee{position:absolute;border:1px solid #4af;background:rgba(68,170,255,.15);pointer-events:none;display:none;z-index:40}
  #export{position:sticky;bottom:0;background:#1a1a1a;border-top:1px solid #333;padding:10px 16px;display:flex;gap:10px;align-items:center}
  #export button{background:#4a8;border:0;border-radius:6px;padding:8px 14px;font-weight:700;cursor:pointer}
  textarea{flex:1;height:54px;background:#0c0c0c;color:#9f9;border:1px solid #333;border-radius:6px;font-family:ui-monospace,monospace;font-size:12px;padding:6px}
</style></head><body>
<header>
  <h1>Photo sort — 2026-05-20 · 190 photos · capture-time order</h1>
  <p class="hint">Drag a box across thumbnails to select (or click / shift-click). Then click a case button to tag them. Tag again to re-assign. Red dashes = capture gap &gt;90s. When done, hit <b>Export</b> (saves mapping.json + fills the box to paste back).</p>
  <div class="palette" id="palette"></div>
</header>
<div class="grid" id="grid"><div id="marquee"></div></div>
<div id="export">
  <button onclick="doExport()">Export mapping</button>
  <textarea id="out" readonly placeholder="mapping appears here — also downloads as mapping.json"></textarea>
</div>
<script>
const PHOTOS=[${DATA}];
const CASES=[
  ["B07 Signia","#ffd24a"],["C10 Oticon Agil Pro","#9ad"],["B01(small) Moxi2 Kiss","#f9a"],
  ["B17 Oticon Acto","#8e8"],["B19 Oticon Ino P","#fb8"],["C16 GN ReSound","#bdf"],
  ["C25 Oticon Ino","#ccc"],["B01(large) Sonic","#ccc"],["SKIP / not a device","#666"]
];
const colorOf={}; CASES.forEach(c=>colorOf[c[0]]=c[1]);
let activeCase=CASES[0][0];
const grid=document.getElementById('grid'), pal=document.getElementById('palette');
CASES.forEach((c,i)=>{const b=document.createElement('button');b.textContent=c[0];b.style.background=c[1];
  b.onclick=()=>{assign(c[0]); setActive(c[0]);};pal.appendChild(b);});
const delBtn=document.createElement('button');delBtn.textContent='🗑 DELETE';delBtn.style.background='#e44';delBtn.style.color='#fff';
delBtn.onclick=()=>markDelete();pal.appendChild(delBtn);
const revealBtn=document.createElement('button');revealBtn.textContent='👁 show tagged';revealBtn.className='act';
revealBtn.onclick=()=>{document.body.classList.toggle('reveal');revealBtn.textContent=document.body.classList.contains('reveal')?'🙈 hide tagged':'👁 show tagged';upd();};pal.appendChild(revealBtn);
const st=document.createElement('span');st.id='status';pal.appendChild(st);
function setActive(name){activeCase=name;[...pal.querySelectorAll('button')].forEach(b=>b.classList.toggle('act',b.textContent===name));upd();}

// build cells
let prev=null;
PHOTOS.forEach(p=>{
  if(prev!==null){const g=p.epoch-prev; if(g>90){const s=document.createElement('div');s.className='sep';s.innerHTML='<span>gap '+Math.floor(g/60)+'m '+(g%60)+'s</span>';grid.appendChild(s);}}
  const d=document.createElement('div');d.className='cell';d.dataset.num=p.num;
  d.innerHTML='<img loading="lazy" src="thumbs/'+p.file+'.jpg"><div class="cap"><span class="num">'+p.num+'</span><br><span class="time">'+p.t+'</span></div>';
  d.addEventListener('click',e=>{
    if(e.shiftKey&&lastClicked){selRange(lastClicked,d);}
    else{d.classList.toggle('sel');lastClicked=d;}
    upd();
  });
  grid.appendChild(d); prev=p.epoch;
});
let lastClicked=null;
const cells=()=>[...grid.querySelectorAll('.cell')];
function selRange(a,b){const cs=cells();let i=cs.indexOf(a),j=cs.indexOf(b);if(i>j)[i,j]=[j,i];for(let k=i;k<=j;k++)if(!cs[k].classList.contains('done'))cs[k].classList.add('sel');}
function assign(name){const sel=cells().filter(c=>c.classList.contains('sel'));sel.forEach(c=>{c.dataset.label=name;c.classList.remove('del');c.style.borderColor=colorOf[name];let t=c.querySelector('.tag');if(!t){t=document.createElement('div');t.className='tag';c.appendChild(t);}t.textContent=name.split(' ')[0];t.style.background=colorOf[name];c.classList.remove('sel');c.classList.add('done');});upd();}
function markDelete(){cells().filter(c=>c.classList.contains('sel')).forEach(c=>{c.dataset.label='_DELETE';c.classList.add('del','done');c.classList.remove('sel');let t=c.querySelector('.tag');if(!t){t=document.createElement('div');t.className='tag';c.appendChild(t);}t.textContent='🗑';t.style.background='#e44';c.style.borderColor='#e44';});upd();}
function unmarkDelete(){cells().filter(c=>c.classList.contains('sel')||c.classList.contains('del')).forEach(c=>{if(c.dataset.label==='_DELETE'){delete c.dataset.label;c.classList.remove('del','done','sel');c.style.borderColor='transparent';const t=c.querySelector('.tag');if(t)t.remove();}});upd();}
function upd(){const all=cells();const tagged=all.filter(c=>c.dataset.label&&c.dataset.label!=='_DELETE').length;const del=all.filter(c=>c.dataset.label==='_DELETE').length;const left=all.length-tagged-del;const sel=all.filter(c=>c.classList.contains('sel')).length;st.textContent=' active: '+activeCase+'  ·  selected: '+sel+'  ·  remaining: '+left+'  ·  tagged: '+tagged+'  ·  to-delete: '+del;saveState();}
let saveTimer=null;
function buildState(){const assignments={},selected=[],deletes=[];cells().forEach(c=>{const n=c.dataset.num;if(c.classList.contains('sel'))selected.push(n);if(c.dataset.label==='_DELETE')deletes.push(n);else if(c.dataset.label)(assignments[c.dataset.label]=assignments[c.dataset.label]||[]).push(n);});return{updated:new Date().toISOString(),assignments,deletes,selected};}
function saveState(){if(saveTimer)clearTimeout(saveTimer);saveTimer=setTimeout(()=>{fetch('/state',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify(buildState())}).catch(()=>{const s=document.getElementById('status');if(s)s.textContent+='  ⚠ NOT SAVED (run server.py + open via http://localhost:8765)';});},250);}
function applyTag(c,name){c.dataset.label=name;c.classList.add('done');let t=c.querySelector('.tag');if(!t){t=document.createElement('div');t.className='tag';c.appendChild(t);}if(name==='_DELETE'){c.classList.add('del');t.textContent='🗑';t.style.background='#e44';c.style.borderColor='#e44';}else{c.classList.remove('del');t.textContent=name.split(' ')[0];t.style.background=colorOf[name]||'#888';c.style.borderColor=colorOf[name]||'#888';}}
async function restoreState(){try{const r=await fetch('state.json',{cache:'no-store'});if(!r.ok)return;const s=await r.json();const byNum={};cells().forEach(c=>byNum[c.dataset.num]=c);for(const label in (s.assignments||{}))s.assignments[label].forEach(n=>{if(byNum[n])applyTag(byNum[n],label);});(s.deletes||[]).forEach(n=>{if(byNum[n])applyTag(byNum[n],'_DELETE');});upd();}catch(e){}}

// marquee drag-select
let sx,sy,dragging=false;const mq=document.getElementById('marquee');
grid.addEventListener('mousedown',e=>{if(e.target.closest('.cell'))return;dragging=true;const r=grid.getBoundingClientRect();sx=e.clientX-r.left;sy=e.clientY-r.top+grid.scrollTop;mq.style.display='block';if(!e.shiftKey)cells().forEach(c=>c.classList.remove('sel'));e.preventDefault();});
window.addEventListener('mousemove',e=>{if(!dragging)return;const r=grid.getBoundingClientRect();const x=e.clientX-r.left,y=e.clientY-r.top;const l=Math.min(sx,x),t=Math.min(sy,y),w=Math.abs(x-sx),h=Math.abs(y-sy);Object.assign(mq.style,{left:l+'px',top:t+'px',width:w+'px',height:h+'px'});const box={left:l+r.left,top:t+r.top,right:l+r.left+w,bottom:t+r.top+h};cells().forEach(c=>{if(c.classList.contains('done'))return;const cb=c.getBoundingClientRect();const hit=!(cb.right<box.left||cb.left>box.right||cb.bottom<box.top||cb.top>box.bottom);if(hit)c.classList.add('sel');});upd();});
window.addEventListener('mouseup',()=>{if(dragging){dragging=false;mq.style.display='none';}});

function doExport(){
  const map={};cells().forEach(c=>{if(c.dataset.label){(map[c.dataset.label]=map[c.dataset.label]||[]).push(c.dataset.num);}});
  const json=JSON.stringify(map,null,2);
  // human-readable ranges
  let txt='';for(const k in map){const ns=map[k].map(Number).sort((a,b)=>a-b);txt+=k+': '+ns.join(',')+'\n';}
  document.getElementById('out').value=txt||'(nothing tagged yet)';
  const blob=new Blob([json],{type:'application/json'});const a=document.createElement('a');a.href=URL.createObjectURL(blob);a.download='mapping.json';a.click();
}
setActive(CASES[0][0]);
restoreState();
</script></body></html>
HEAD
echo "WROTE $(pwd)/$HTML"
