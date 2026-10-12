const fs=require('fs'),vm=require('vm'),assert=require('assert');
// Generate fixtures with MESO_RENDER_EVIDENCE=<directory> in the SwiftPM meso test lane.
const root=process.argv[2];
assert(root, 'Usage: node MesoDashboardParity.cjs <fixture-directory>');
const html=fs.readFileSync(root+'/page.html','utf8');
function extract(name,next){const a=html.indexOf('function '+name+'('),b=html.indexOf('function '+next+'(',a);assert(a>=0&&b>a);return html.slice(a,b);}
const functions=extract('parseDateValue','dateToMillis')+extract('escapeHtml','diagnosticDisclosure')+extract('controlTime','controlAreaDescription')+extract('renderMesoSummary','applySnapshot')+extract('swapHTML','updateSlot');
const context={URL};vm.createContext(context);vm.runInContext(functions,context);
const snapshot=JSON.parse(fs.readFileSync(root+'/snapshot.json','utf8'));
assert.equal(context.renderMesoActivity(snapshot.mesoActivity),fs.readFileSync(root+'/activity.html','utf8'));
for(const c of JSON.parse(fs.readFileSync(root+'/render-cases.json','utf8'))) assert.equal(context.renderMesoActivity(c.activity),c.html);
assert.equal(context.renderMesoSummary(snapshot.redLights.spcMesoIngest),fs.readFileSync(root+'/summary.html','utf8'));
assert.equal(context.renderMesoActivity(null),'<p class="empty">Meso activity unavailable in this snapshot. Awaiting worker refresh.</p>');
let empty={...snapshot.mesoActivity,entries:[],capped:false};
assert(context.renderMesoActivity(empty).endsWith('<p class="empty">No active or recently issued discussions.</p>'));
for(const label of ['Pending','Active','Expired']){
 const e={...snapshot.mesoActivity.entries[0], validStart:snapshot.mesoActivity.refreshedAt, validEnd:new Date(Date.parse(snapshot.mesoActivity.refreshedAt)+3600000).toISOString()};
 // Compare actual dates rather than any fixture-specific clock guess.
 const time=Date.parse(e.validStart)+(label==='Pending'?-1000:label==='Active'?0:1e10);
 assert(context.renderMesoActivity({...snapshot.mesoActivity,refreshedAt:new Date(time).toISOString(),entries:[e]}).includes('MD 42 · '+label));
}
let sparse={...snapshot.mesoActivity.entries[0],watchProbability:null,watchProbabilityText:'',peakWindMPH:null,hailRangeInches:null,tornadoStrength:null,concerning:null,sourceURL:'javascript:alert(1)',geometryAvailable:false};
let rendered=context.renderMesoActivity({...snapshot.mesoActivity,entries:[sparse]});
assert(rendered.includes('Watch probability: Unknown'));assert(!rendered.includes('href='));assert(!rendered.includes('Peak wind'));assert(rendered.includes('No geometry'));
let script=html.match(/<script>([\s\S]*?)<\/script>/)[1];new vm.Script(script);
// Minimal DOM adapter exercises the real refresh function without a browser dependency.
const document={activeElement:null};
function disclosure(key,open=false){
 const d={dataset:key===undefined?{}:{disclosureKey:key},open};
 d.summary={closest:()=>d,focus:()=>{document.activeElement=d.summary;}};
 d.querySelector=()=>d.summary;return d;
}
let rows=[disclosure('old',true),disclosure('other')];
const node={querySelectorAll:selector=>selector==='details'?rows:rows.map(d=>d.summary),set innerHTML(keys){rows=keys.map(k=>disclosure(k));document.activeElement=null;}};
document.getElementById=()=>node;context.document=document;
document.activeElement=rows[0].summary;
context.swapHTML('meso-activity',['new','old','other']);
assert.equal(rows[0].open,false);assert.equal(rows[1].open,true);assert.equal(document.activeElement,rows[1].summary);
context.swapHTML('meso-activity',['new','other']);
assert(rows.every(d=>!d.open));assert.equal(document.activeElement,null);
rows=[disclosure(undefined,true),disclosure(undefined)];document.activeElement=rows[0].summary;
context.swapHTML('existing-card',[undefined,undefined]);
assert(rows[0].open);assert.equal(document.activeElement,rows[0].summary);
fs.writeFileSync(root+'/parity-result.json',JSON.stringify({status:'passed',checks:['exact SSR/live activity HTML','exact SSR/live summary HTML','exact SSR/live unavailable empty expired pending sparse HTML','unavailable','empty','pending','active start boundary','expired','sparse threats and unsafe URL','complete script syntax','keyed disclosure prepend','keyed disclosure removal','unkeyed disclosure compatibility']},null,2));
console.log('13 rendering and refresh checks passed');
