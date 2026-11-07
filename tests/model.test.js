const fs = require("fs"), vm = require("vm"), assert = require("assert");
const code = fs.readFileSync(require("path").join(__dirname, "..", "Model.js"), "utf8").replace(".pragma library", "");
const model = {}; vm.createContext(model); vm.runInContext(code, model);
assert.deepStrictEqual(JSON.parse(JSON.stringify(model.candidates({Self:{Online:true,DNSName:"one.ts.net.",ID:"1"},Peer:{a:{Online:true,DNSName:"two.ts.net.",StableID:"2"},b:{Online:false,DNSName:"no.ts.net",ID:"3"}}}))), [{id:"1",dns:"one.ts.net",name:"one.ts.net"},{id:"2",dns:"two.ts.net",name:"two.ts.net"}]);
assert(model.summary('{"product":"gravedecay","api_version":1,"node":{},"resources":{},"activity":{},"health":{},"links":{}}'));
assert.equal(model.summary('{"product":"nope"}'), null);
assert.equal(model.safeDnsName("grave.tailnet.ts.net."), "grave.tailnet.ts.net");
assert.equal(model.safeDnsName("grave.ts.net@evil.example"), "");
assert.equal(model.safeDnsName("https://evil.example"), "");
assert.equal(model.safePath("/grave/"), "/grave/");
assert.equal(model.safePath("//evil.example"), "");
assert.equal(model.safePath("/\\evil"), "");
assert.equal(model.safeDesktopEntry("gravedecay.desktop"), "gravedecay.desktop");
assert.equal(model.safeDesktopEntry("grave;rm.desktop"), "");
assert.equal(model.safeHyprAddress("0xAbC123"), "0xabc123");
assert.equal(model.safeHyprAddress("0x1; os.execute('no')"), "");
assert.equal(model.activityUrl("grave.tailnet.ts.net", "/threads/env/thread"), "https://grave.tailnet.ts.net/threads/env/thread");
assert.equal(model.activityUrl("grave.tailnet.ts.net", "http://127.0.0.1:4711/threads/env/thread"), "https://grave.tailnet.ts.net/threads/env/thread");
assert.equal(model.activityUrl("grave.tailnet.ts.net", "https://mac.tailnet.ts.net/threads/env/thread"), "https://mac.tailnet.ts.net/threads/env/thread");
assert.equal(model.activityUrl("grave.tailnet.ts.net", "https://evil.example/threads/env/thread"), "");
assert.equal(model.activityUrl("grave.tailnet.ts.net", "https://mac.tailnet.ts.net@evil.example/thread"), "");
const healthy = {reachable:true,summary:{health:{services_failed:0,containers_problem:0},activity:{sessions_live:0,sessions_frozen:0}}};
const active = {reachable:true,summary:{health:{services_failed:0,containers_problem:0},activity:{sessions_live:2,sessions_frozen:0}}};
const t3active = {reachable:true,summary:healthy.summary,t3Activity:{status:"ok",threads:[{phase:"working"},{phase:"waiting_input"}]}};
const warning = {reachable:true,summary:{health:{services_failed:1,containers_problem:2},activity:{}}};
assert.equal(model.state(healthy), "healthy");
assert.equal(model.state(active), "active");
assert.equal(model.state(t3active), "active");
assert.equal(model.state(warning), "warning");
assert.equal(model.state({reachable:false,summary:healthy.summary}), "unreachable");
assert.equal(model.problems(warning.summary), 3);
assert.equal(model.stateLabel(warning), "3 ISSUES");
assert.equal(model.formatDuration(439592), "5d 2h");
assert.equal(model.formatAge(1000, 6000), "just now");
assert.equal(model.formatAge(1000, 66000), "1m ago");
assert(model.phraseBucket(healthy).includes("Rest in production"));
const t3 = model.t3Activity('{"status":"ok","updated_at":"2026-09-02T00:00:00Z","threads":[{"phase":"completed","title":"done"},{"phase":"working","title":"work"},{"phase":"waiting_approval","title":"approve"},{"phase":"unknown"}]}');
assert(t3);
assert.deepStrictEqual(JSON.parse(JSON.stringify(model.t3Counts(t3))), {working:1,attention:1,failed:0,completed:1,active:2});
assert.deepStrictEqual(JSON.parse(JSON.stringify(model.actionableT3Threads(t3, 2).map(t => t.title))), ["approve", "work"]);
assert.equal(model.t3Activity('{"status":"private","threads":[]}'), null);

// ---- API transport ----
const plain = (value) => JSON.parse(JSON.stringify(value));
assert.equal(model.apiResponse('{"ok":true}\nHTTP 200\n', 0).ok, true);
assert.equal(model.apiResponse('{"ok":false,"error":"busy","output":"A turn is running"}\nHTTP 409\n', 0).message, "A turn is running");
assert.equal(model.apiResponse('{"ok":false,"error":"busy"}\nHTTP 409\n', 0).error, "busy");
assert.equal(model.apiResponse('\nHTTP 000\n', 0).code, 0);
assert.equal(model.apiResponse("", 2).message, "Request refused by the plugin");
assert.equal(model.apiResponse('not json\nHTTP 200\n', 0).ok, false);
assert.match(model.newId(1794059485423, () => 0.5), /^1794059485-8{32}$/);
assert.match(model.newId(Date.now()), /^[0-9]{10}-[0-9a-f]{32}$/);
assert.equal(model.safeId("1794059485-57344bf2b45d4fcda75bbf9124c37dc6"), "1794059485-57344bf2b45d4fcda75bbf9124c37dc6");
assert.equal(model.safeId("1794059485-57344bf2&after=0"), "");
assert.equal(model.safeDiggerName("wl"), "wl");
assert.equal(model.safeDiggerName("wl&id=x"), "");
assert.equal(model.cleanText("a\u0000b\u001bc\nd", 100), "abc\nd");
assert.equal(model.cleanText("abcdef", 4), "abc…");

// ---- Probe ----
const caps = {product:"gravedecay",api_version:1,platform:"linux",routes:{GET:["keeper","diggers","admin/releases","admin/update-status"],POST:["keeper","keeper/turn","diggers/ask","admin/upgrade"]},keeper:{provider:"codex",model:""}};
assert.deepStrictEqual(plain(model.capabilities(JSON.stringify(caps))), {platform:"linux",keeper:{provider:"codex",model:""},diggers:true,releases:true,upgrade:true});
assert.deepStrictEqual(plain(model.capabilities(JSON.stringify({...caps,routes:{GET:[],POST:[]}}))), {platform:"linux",keeper:null,diggers:false,releases:false,upgrade:false});
assert.equal(model.capabilities('{"product":"other","api_version":1,"routes":{}}'), null);
const diggerRow = {name:"wl",provider:"codex",identity:"dedicated",repo:"app",enabled:true,live:true,paused:false,pause:null,loggedIn:true,queue:2,running:null,today:{turns:3,usd:1.234},limits:{turns:40,usd:5},slack:{connected:true,error:null,approvals:1},last_verdict:"pass",prompts:[{label:"New label",template:"Create white label {name}"}]};
const rows = model.diggers(JSON.stringify({diggers:[diggerRow,{name:"Bad Name"}],invalid:[]}));
assert.equal(rows.length, 1);
assert.equal(model.diggerStatus(rows[0]), "2 queued");
assert.equal(model.budgetLabel(rows[0]), "$1.23/5 · 3/40 turns");
assert.equal(model.diggerApprovals(rows[0]), 1);
assert.equal(model.diggerNeedsAttention(rows[0]), true);
assert.equal(model.diggerStatus({...rows[0],pause:"budget"}), "budget paused");
assert.equal(model.diggerStatus({...rows[0],loggedIn:false}), "signed out");
assert.equal(model.diggerStatus({...rows[0],enabled:false}), "disabled");
const probed = model.probe(JSON.stringify({reachable:true,
  summary:JSON.stringify({product:"gravedecay",api_version:1,node:{},resources:{},activity:{},health:{},links:{}}),
  t3:"", capabilities:JSON.stringify(caps), diggers:JSON.stringify({diggers:[diggerRow]}),
  keeper:JSON.stringify({provider:"codex",model:"",conversations:[{id:"1794059485-57344bf2b45d4fcda75bbf9124c37dc6",state:"succeeded",summary:"All good\nmore",updated_at:2},{id:"bad",state:"running"}]})}));
assert(probed && probed.capabilities.keeper);
assert.equal(probed.diggers.length, 1);
assert.deepStrictEqual(plain(probed.keeper.conversations.map(c => c.summary)), ["All good"]);
assert.equal(model.probe('{"reachable":false}'), null);
assert.equal(model.probe(JSON.stringify({reachable:true,summary:'{"product":"nope"}'})), null);

// ---- Conversations ----
const record = model.conversation({id:"1794059485-57344bf2b45d4fcda75bbf9124c37dc6",state:"running",events:[
  {seq:1,type:"text",name:"owner",text:"how is it"},
  {seq:2,type:"text",name:"",text:"Checking"},
  {seq:3,type:"tool_call",name:"mcp__keeper__get_logs",text:'{"target": "dash"}'},
  {seq:4,type:"tool_result",name:"mcp__keeper__get_logs",text:"lots of logs"},
  {seq:5,type:"error",name:"",text:"boom"},
  {seq:6,type:"weird",text:"x"}]});
assert.equal(record.events.length, 5);
assert.equal(model.conversationBusy(record), true);
assert.equal(model.conversationBusy({...record,state:"succeeded"}), false);
assert.equal(model.conversationBusy({...record,state:"succeeded",settling:true}), true);
assert.deepStrictEqual(plain(model.chatLines(record.events, "keeper").map(l => l.role + ":" + l.text)), ["owner:how is it","agent:Checking",'tool:→ get_logs {"target": "dash"}',"error:boom"]);
assert.equal(model.lastSeq(record.events), 5);
assert.deepStrictEqual(plain(model.mergeEvents(record.events.slice(0, 2), record.events.slice(1)).map(e => e.seq)), [1,2,3,4,5]);
assert.equal(model.hasOwnerText(record.events, " how is it "), true);
assert.equal(model.conversation({id:"nope"}), null);
assert.equal(model.conversationStateLabel({state:"queued",phase:"open",queued:1}), "queued for the digger");
assert.equal(model.conversationStateLabel({state:"succeeded",phase:"finished",result:{verdict:"pass"}}), "finished · pass");

// ---- Updates ----
const linux = model.releaseInfo({current:"v0.36.0",checkout:"v0.36.0",channel:"release",releases:["v0.38.0","v0.37.0","v0.36.0","v0.9.0"]});
assert.equal(linux.latest, "v0.38.0");
assert.equal(model.releaseLabel(linux), "v0.36.0");
const branch = model.releaseInfo({current:"",checkout:"fix/thing",channel:"release",releases:["v0.38.0"]});
assert.equal(branch.latest, "");
assert.equal(branch.newestRelease, "v0.38.0");
assert.equal(model.releaseLabel(branch), "checkout fix/thing");
assert.equal(model.releaseInfo({current:"v0.37.0",available:false,latest:"",releases:[]}).latest, "");
assert.equal(model.releaseInfo({current:"v0.37.0",available:true,latest:"v0.38.0",releases:["v0.38.0"]}).latest, "v0.38.0");
assert.equal(model.releaseInfo({current:"v0.38.0",releases:["v0.38.0; reboot"]}).latest, "");
assert.equal(model.compareVersions("v0.10.0", "v0.9.9"), 1);
assert.equal(model.updateStatus('{"state":"running","attempt":"a1"}').state, "running");
assert.equal(model.updateStatus('{"state":"exploded"}'), null);
const plugin = model.pluginUpdate('{"git":true,"local":"1.2.0","remote":"1.3.0","behind":4,"dirty":false,"error":""}');
assert.equal(plugin.available, true);
assert.equal(model.pluginUpdateLabel(plugin), "Plugin 1.3.0 is available (you have 1.2.0)");
assert.equal(model.pluginUpdateLabel(model.pluginUpdate('{"git":true,"local":"1.3.0","remote":"1.3.0","behind":1}')), "1 new plugin change available");
assert.equal(model.pluginUpdate('{"git":false,"local":"1.3.0"}').available, false);
console.log("model tests passed");
