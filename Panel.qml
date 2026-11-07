import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model

Panel {
  id: root
  moduleName: "projectmushroom.gravedecay"
  ipcTarget: moduleName
  manageIpc: false

  // Every grave request goes through this helper: tailnet-pinned, HTTPS-only,
  // allowlisted routes, request bodies on stdin.
  readonly property string helper: decodeURIComponent(String(Qt.resolvedUrl("bin/gravedecay-api")).replace(/^file:\/\//, ""))

  property var nodes: []
  property string selectedId: ""
  property bool refreshing: false
  property var pending: []
  property var discovered: []
  property var probing: null
  property bool completedInitialScan: false
  property double nowMs: Date.now()
  property int phraseIndex: 0
  property string pendingDashboardUrl: ""
  property string pendingDesktopEntry: ""
  property int pendingWorkspace: 1

  // Updates, keyed by node ID so a discovery pass never drops them.
  property var releases: ({})
  property var upgrades: ({})
  property var releaseQueue: []
  property var releaseProbing: null
  property string confirmUpgradeId: ""
  property var pluginUpdate: null
  property double pluginCheckedAt: 0

  // One Keeper or digger conversation at a time.
  property bool chatOpen: false
  property string chatKind: ""
  property string chatNodeId: ""
  property string chatDns: ""
  property string chatHost: ""
  property string chatDigger: ""
  property string chatConversation: ""
  property var chatRecord: null
  property var chatEvents: []
  property var chatList: []
  property string chatPending: ""
  property string chatError: ""
  property bool chatSending: false
  property bool chatLoading: false
  property var chatRetry: null
  property string chatConfirm: ""
  property double chatFollowUntil: 0

  property var apiQueue: []
  property var apiCurrent: null

  readonly property int refreshIntervalSec: Math.round(Model.clamp(settings && settings.refreshIntervalSec !== undefined ? settings.refreshIntervalSec : 45, 30, 300))
  readonly property bool notificationsEnabled: settings && settings.notificationsEnabled === true
  readonly property bool updateChecks: !(settings && settings.updateChecks === false)
  readonly property string desktopEntry: Model.safeDesktopEntry(settings && settings.desktopEntry !== undefined ? settings.desktopEntry : "gravedecay.desktop")
  readonly property int historySamples: Math.round(Model.clamp(settings && settings.historySamples !== undefined ? settings.historySamples : 60, 12, 120))
  readonly property color foreground: bar ? bar.foreground : Color.popups.text
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property color track: Style.selectedFillFor(foreground, Color.accent)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family
  readonly property var current: findNode(selectedId) || (nodes.length ? nodes[0] : null)
  readonly property string currentState: Model.state(current)
  readonly property var currentT3Counts: Model.t3Counts(current ? current.t3Activity : null)
  readonly property bool currentT3Available: Model.t3Available(current ? current.t3Activity : null)
  readonly property var currentCaps: current && current.capabilities ? current.capabilities : null
  readonly property bool currentHasKeeper: !!current && current.reachable && !!currentCaps && !!currentCaps.keeper
  readonly property var currentDiggers: current && current.reachable && current.diggers ? current.diggers : []
  readonly property var currentRelease: current && releases[current.id] ? releases[current.id] : null
  readonly property var currentUpgrade: current && upgrades[current.id] ? upgrades[current.id] : null
  readonly property int reachableCount: countWhere(function(node) { return node.reachable !== false })
  readonly property int warningCount: countWhere(function(node) { var s = Model.state(node); return s === "warning" || s === "unreachable" })
  readonly property int fleetT3Feeds: countWhere(function(node) { return Model.t3Available(node.t3Activity) })
  readonly property int fleetT3Working: t3Total("working")
  readonly property int fleetT3Attention: t3Total("attention")
  readonly property int fleetApprovals: approvalsTotal()
  readonly property int fleetUpdates: countWhere(function(node) { var r = root.releases[node.id]; return !!(r && r.info && r.info.latest) })
  readonly property bool pluginUpdateAvailable: !!pluginUpdate && pluginUpdate.available
  readonly property bool chatBusy: chatSending || Model.conversationBusy(chatRecord)
  readonly property var chatDiggerRow: findDigger(findNode(chatNodeId), chatDigger)
  readonly property var chatLines: Model.chatLines(chatEvents, chatKind === "keeper" ? "keeper" : chatDigger, 80)
  readonly property string phrase: {
    if (!current) return refreshing ? "Knocking on crypts" : "No graves found on this tailnet"
    var phrases = Model.phraseBucket(current)
    return phrases[phraseIndex % phrases.length]
  }
  readonly property color stateColor: currentT3Counts.attention > 0 || currentState === "warning" ? urgent : currentState === "unreachable" ? dim : foreground

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  // ---- Fleet --------------------------------------------------------------

  function findNode(id) {
    for (var i = 0; i < nodes.length; i++) if (String(nodes[i].id) === String(id)) return nodes[i]
    return null
  }
  function findDigger(node, name) {
    var rows = node && node.diggers ? node.diggers : []
    for (var i = 0; i < rows.length; i++) if (rows[i].name === name) return rows[i]
    return null
  }
  function countWhere(predicate) {
    var count = 0
    for (var i = 0; i < nodes.length; i++) if (predicate(nodes[i])) count++
    return count
  }
  function t3Total(name) {
    var total = 0
    for (var i = 0; i < nodes.length; i++) total += Number(Model.t3Counts(nodes[i].t3Activity)[name] || 0)
    return total
  }
  function approvalsTotal() {
    var total = 0
    for (var i = 0; i < nodes.length; i++) {
      var rows = nodes[i].reachable && nodes[i].diggers ? nodes[i].diggers : []
      for (var j = 0; j < rows.length; j++) total += Model.diggerApprovals(rows[j])
    }
    return total
  }
  function nodeIndex(node) {
    if (!node) return 0
    for (var i = 0; i < nodes.length; i++) if (nodes[i].id === node.id) return i
    return 0
  }
  function selectRelative(delta) {
    if (!nodes.length) return
    selectedId = nodes[(nodeIndex(current) + delta + nodes.length) % nodes.length].id
    phraseIndex = 0
    confirmUpgradeId = ""
  }
  function refresh() {
    if (refreshing) return
    refreshing = true
    pending = []
    discovered = []
    status.command = ["tailscale", "status", "--json"]
    status.running = true
  }
  function parseStatus(raw) {
    var parsed
    try { parsed = JSON.parse(raw) } catch (_) { finishDiscovery(); return }
    pending = Model.candidates(parsed)
    probeNext()
  }
  function previousNode(id) {
    for (var i = 0; i < nodes.length; i++) if (nodes[i].id === id) return nodes[i]
    return null
  }
  function appendHistory(previous, summary) {
    var history = previous && previous.history ? previous.history.slice() : []
    history.push({ at: Date.now(), cpu: Number(summary.resources.cpu_pct), memory: Number(summary.resources.memory_pct), disk: Number(summary.resources.disk_pct) })
    while (history.length > historySamples) history.shift()
    return history
  }
  function offline(old) {
    return { id: old.id, dns: old.dns, name: old.name, reachable: false, lastSeen: old.lastSeen, summary: old.summary, t3Activity: old.t3Activity || null, capabilities: old.capabilities || null, diggers: old.diggers || [], keeper: old.keeper || null, history: old.history || [] }
  }
  function probeNext() {
    if (!pending.length) { finishDiscovery(); return }
    probing = pending.shift()
    probeProc.command = ["bash", helper, "probe", probing.dns]
    probeProc.running = true
  }
  function recordProbe(value) {
    var old = previousNode(probing.id)
    if (!value) { if (old) discovered.push(offline(old)); return }
    discovered.push({ id: probing.id, dns: probing.dns, name: probing.name, reachable: true, lastSeen: Date.now(), summary: value.summary, t3Activity: value.t3Activity, capabilities: value.capabilities, diggers: value.diggers, keeper: value.keeper, history: appendHistory(old, value.summary) })
  }
  function containsDiscovered(id) {
    for (var i = 0; i < discovered.length; i++) if (discovered[i].id === id) return true
    return false
  }
  function notifyNow(title, body) {
    if (!notificationsEnabled || notify.running) return
    notify.command = ["notify-send", "--app-name=Gravedecay", title, body]
    notify.running = true
  }
  function maybeNotify(oldNode, nextNode) {
    if (!completedInitialScan || !notificationsEnabled || !oldNode || notify.running) return
    var beforeT3 = Model.t3Counts(oldNode.t3Activity), afterT3 = Model.t3Counts(nextNode.t3Activity)
    if (afterT3.attention > beforeT3.attention) {
      var attention = afterT3.attention
      notifyNow("Gravedecay · " + nextNode.name, attention + " T3 chat" + (attention === 1 ? " needs" : "s need") + " you")
      return
    }
    for (var i = 0; i < (nextNode.diggers || []).length; i++) {
      var row = nextNode.diggers[i], before = findDigger(oldNode, row.name)
      if (Model.diggerApprovals(row) > Model.diggerApprovals(before)) {
        notifyNow("Gravedecay · " + nextNode.name, row.name + " waits for " + Model.diggerApprovals(row) + " Slack approval" + (Model.diggerApprovals(row) === 1 ? "" : "s"))
        return
      }
    }
    var beforeStateNode = oldNode
    if (Model.t3Available(oldNode.t3Activity) && !Model.t3Available(nextNode.t3Activity))
      beforeStateNode = { reachable: oldNode.reachable, summary: oldNode.summary, t3Activity: null }
    var before = Model.state(beforeStateNode), after = Model.state(nextNode)
    if (before === after) return
    var body = after === "healthy" ? "Buried, not broken — the grave recovered"
      : after === "active" ? "Agents started the graveyard shift"
      : after === "frozen" ? "Agents entered torpor"
      : after === "warning" ? Model.stateLabel(nextNode) + " · the dead are restless"
      : "Nothing answers from the crypt"
    notifyNow("Gravedecay · " + nextNode.name, body)
  }
  function finishDiscovery() {
    for (var i = 0; i < nodes.length; i++) {
      var old = nodes[i]
      if (!containsDiscovered(old.id)) discovered.push(offline(old))
    }
    discovered.sort(function(a, b) { if (a.reachable !== b.reachable) return a.reachable ? -1 : 1; return String(a.name).localeCompare(String(b.name)) })
    for (var j = 0; j < discovered.length; j++) maybeNotify(previousNode(discovered[j].id), discovered[j])
    nodes = discovered.slice()
    if (nodes.length && !findNode(selectedId)) selectedId = nodes[0].id
    refreshing = false
    completedInitialScan = true
    phraseIndex = 0
    queueReleaseChecks("")
  }

  // ---- Requests -------------------------------------------------------------

  // One request at a time; callbacks get Model.apiResponse().
  function api(method, dns, route, body, done) {
    apiQueue.push({ method: method, dns: dns, route: route, body: body === undefined ? null : body, done: done })
    apiPump()
  }
  function apiPump() {
    if (apiProc.running || apiCurrent || !apiQueue.length) return
    apiCurrent = apiQueue.shift()
    apiProc.command = ["bash", helper, "request", apiCurrent.method, apiCurrent.dns, apiCurrent.route]
    apiProc.running = true
  }
  function apiFinished(raw, code) {
    var request = apiCurrent
    apiCurrent = null
    if (request && request.done) {
      try { request.done(Model.apiResponse(raw, code)) } catch (error) { console.warn("gravedecay: " + error) }
    }
    apiPump()
  }

  // ---- Grave updates ----------------------------------------------------------

  function setRelease(id, value) { var next = Object.assign({}, releases); next[id] = value; releases = next }
  function setUpgrade(id, value) {
    var next = Object.assign({}, upgrades)
    if (value) next[id] = value; else delete next[id]
    upgrades = next
  }
  function queueReleaseChecks(forceId) {
    for (var i = 0; i < nodes.length; i++) {
      var node = nodes[i], known = releases[node.id]
      if (!node.reachable || !node.capabilities || !node.capabilities.releases) continue
      if (node.id !== forceId && known && Date.now() - known.checkedAt < 15 * 60 * 1000) continue
      var queued = releaseProbing && releaseProbing.id === node.id
      for (var j = 0; j < releaseQueue.length; j++) if (releaseQueue[j].id === node.id) queued = true
      if (!queued) releaseQueue.push({ id: node.id, dns: node.dns })
    }
    releaseNext()
  }
  function releaseNext() {
    if (releaseProc.running || !releaseQueue.length) return
    releaseProbing = releaseQueue.shift()
    releaseProc.command = ["bash", helper, "releases", releaseProbing.dns]
    releaseProc.running = true
  }
  function recordReleases(raw) {
    var value = Model.parseJson(raw), item = releaseProbing
    releaseProbing = null
    if (item && value && value.reachable) {
      var info = Model.releaseInfo(value.releases)
      if (info) setRelease(item.id, { info: info, status: Model.updateStatus(value.status), checkedAt: Date.now() })
    }
    releaseNext()
  }
  function upgradeActive(id) {
    var u = upgrades[id]
    return !!u && (u.state === "checking" || u.state === "queued" || u.state === "running")
  }
  function startUpgrade(node, tag) {
    confirmUpgradeId = ""
    if (!node || !/^v\d+\.\d+\.\d+$/.test(tag) || upgradeActive(node.id)) return
    var base = { dns: node.dns, name: node.name, target: tag, startedAt: Date.now(), previousAttempt: "", sawActive: false }
    setUpgrade(node.id, Object.assign({}, base, { state: "checking", message: "Checking the updater…" }))
    api("GET", node.dns, "admin/update-status", null, function(res) {
      var before = res.ok ? Model.updateStatus(res.data) : null
      if (!before) { setUpgrade(node.id, Object.assign({}, base, { state: "failed", message: res.message || "Cannot read the updater status" })); return }
      if (before.state === "queued" || before.state === "running") { setUpgrade(node.id, Object.assign({}, base, { state: "failed", message: "An update is already running on this grave" })); return }
      base.previousAttempt = before.attempt
      api("POST", node.dns, "admin/upgrade", { tag: tag }, function(res2) {
        // A lost response can still mean the job was accepted: watch, never resubmit.
        if (!res2.ok && res2.code !== 0) { setUpgrade(node.id, Object.assign({}, base, { state: "failed", message: res2.message })); return }
        setUpgrade(node.id, Object.assign({}, base, { state: "queued", message: res2.ok ? "Update queued · the dashboard will restart" : "No answer · watching for the update" }))
      })
    })
  }
  function pollUpgrades() {
    for (var id in upgrades) (function(id) {
      var u = upgrades[id]
      if (u.state !== "queued" && u.state !== "running") return
      if (Date.now() - u.startedAt > 30 * 60 * 1000) { setUpgrade(id, Object.assign({}, u, { state: "unknown", message: "Completion could not be verified · check the grave's dashboard" })); return }
      api("GET", u.dns, "admin/update-status", null, function(res) {
        var now = upgrades[id]
        if (!now || (now.state !== "queued" && now.state !== "running")) return
        var st = res.ok ? Model.updateStatus(res.data) : null
        if (!st) { setUpgrade(id, Object.assign({}, now, { sawActive: true, message: "Waiting for the grave to come back…" })); return }
        var fresh = now.sawActive || (st.attempt && st.attempt !== now.previousAttempt)
        if (st.state === "queued" || st.state === "running") setUpgrade(id, Object.assign({}, now, { state: "running", sawActive: true, message: st.message || "Updating…" }))
        else if (st.state === "failed" && fresh) setUpgrade(id, Object.assign({}, now, { state: "failed", message: "Update failed · " + (st.message || "see the grave's update log") }))
        else if (st.state === "ok" && fresh) {
          setUpgrade(id, Object.assign({}, now, { state: "done", message: "Updated to " + now.target }))
          notifyNow("Gravedecay · " + now.name, "Updated to " + now.target)
          queueReleaseChecks(id)
        } else if (Date.now() - now.startedAt > 3 * 60 * 1000)
          setUpgrade(id, Object.assign({}, now, { state: "unknown", message: "The updater never started · check the grave's dashboard" }))
      })
    })(id)
  }

  // ---- Plugin updates ---------------------------------------------------------

  function checkPluginUpdate() {
    if (!updateChecks || selfCheck.running) return
    pluginCheckedAt = Date.now()
    selfCheck.command = ["bash", helper, "self-check"]
    selfCheck.running = true
  }
  function applyPluginUpdate() {
    if (!pluginUpdateAvailable) return
    Quickshell.execDetached(["bash", helper, "self-update"])
    root.close()
  }

  // ---- Keeper and diggers -------------------------------------------------------

  function openChat(kind, digger) {
    if (!current || !current.reachable) return
    if (kind === "digger" && !Model.safeDiggerName(digger)) return
    chatKind = kind
    chatNodeId = current.id
    chatDns = current.dns
    chatHost = current.summary.node.host || current.name
    chatDigger = kind === "digger" ? digger : ""
    resetConversation()
    chatList = kind === "keeper" && current.keeper ? current.keeper.conversations : []
    chatOpen = true
    refreshChatList()
    focusChatInput()
  }
  function closeChat() {
    chatOpen = false
    resetConversation()
    chatKind = ""
    chatList = []
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }
  function resetConversation() {
    chatConversation = ""
    chatRecord = null
    chatEvents = []
    chatPending = ""
    chatError = ""
    chatRetry = null
    chatConfirm = ""
    chatSending = false
    chatFollowUntil = 0
  }
  function focusChatInput() { Qt.callLater(function() { if (root.chatOpen) chatInput.forceActiveFocus() }) }
  function scrollChatToEnd() { Qt.callLater(function() { panelFlick.contentY = Math.max(0, panelFlick.contentHeight - panelFlick.height) }) }
  function sameChat(kind, conversation) { return chatOpen && chatKind === kind && chatConversation === conversation }
  function refreshChatList() {
    var kind = chatKind, digger = chatDigger
    var route = kind === "keeper" ? "keeper" : "diggers?name=" + digger
    api("GET", chatDns, route, null, function(res) {
      if (!res.ok || chatKind !== kind || chatDigger !== digger) return
      chatList = kind === "keeper" ? ((Model.keeperList(res.data) || {}).conversations || []) : Model.conversationRows(res.data.conversations)
    })
  }
  function conversationOptions() {
    var options = [{ value: "", label: "New conversation" }]
    var seen = {}
    for (var i = 0; i < chatList.length; i++) {
      var row = chatList[i]
      seen[row.id] = true
      var when = row.updatedAt ? Model.formatAge(row.updatedAt * 1000, nowMs) : ""
      options.push({ value: row.id, label: (row.summary || row.state) + (when ? " · " + when : "") })
    }
    if (chatConversation && !seen[chatConversation]) options.push({ value: chatConversation, label: "This conversation" })
    return options
  }
  function selectConversation(id) {
    if (id === chatConversation) return
    resetConversation()
    if (!Model.safeId(id)) { focusChatInput(); return }
    chatConversation = id
    loadConversation()
  }
  function conversationRoute(after) {
    return chatKind === "keeper"
      ? "keeper?id=" + chatConversation + "&after=" + after
      : "diggers/conversation?name=" + chatDigger + "&id=" + chatConversation + "&after=" + after
  }
  function loadConversation() {
    if (!chatConversation || chatLoading) return
    var kind = chatKind, conversation = chatConversation
    chatLoading = true
    api("GET", chatDns, conversationRoute(Model.lastSeq(chatEvents)), null, function(res) {
      chatLoading = false
      if (!sameChat(kind, conversation)) return
      if (!res.ok) {
        // A digger conversation reads as missing until its first request lands.
        if (res.code === 404 && (chatPending || Date.now() < chatFollowUntil)) return
        chatError = res.code === 404 ? "This conversation is gone or expired" : res.message
        return
      }
      applyRecord(res.data)
    })
  }
  function applyRecord(data) {
    var record = Model.conversation(data)
    if (!record || record.id !== chatConversation) return
    var wasBusy = Model.conversationBusy(chatRecord)
    var grew = record.events.length > 0
    chatEvents = Model.mergeEvents(chatEvents, record.events)
    chatRecord = record
    if (!chatRetry) chatError = ""
    if (chatPending && Model.hasOwnerText(chatEvents, chatPending)) chatPending = ""
    if (wasBusy && !Model.conversationBusy(record)) chatSettled()
    if (grew) scrollChatToEnd()
  }
  function chatSettled() {
    chatPending = ""
    refreshChatList()
    if (!root.opened) {
      var who = chatKind === "keeper" ? "The Gravekeeper" : chatDigger
      notifyNow("Gravedecay · " + chatHost, who + (chatRecord && chatRecord.state === "failed" ? " hit a problem" : " answered"))
    }
  }
  function sendChat(text) {
    var message = String(text || "").trim()
    if (!message || message.length > 8000 || chatSending) return false
    if (chatKind === "keeper" && Model.conversationBusy(chatRecord)) { chatError = "The Keeper is still answering"; return false }
    if (chatKind === "digger" && chatRecord && chatRecord.phase === "finished") { chatError = "This conversation has finished · start a new one"; return false }
    chatError = ""
    chatPending = message
    if (chatKind === "keeper") {
      var turn = { conversation: chatConversation || Model.newId(Date.now()), turn: Model.newId(Date.now()), message: message }
      if (!chatConversation) {
        chatConversation = turn.conversation
        chatPost("keeper", { id: turn.conversation }, function() { chatPost("keeper/turn", turn, null, message) }, message)
      } else chatPost("keeper/turn", turn, null, message)
    } else {
      if (!chatConversation) chatConversation = Model.newId(Date.now())
      chatPost("diggers/ask", { name: chatDigger, conversation: chatConversation, request: Model.newId(Date.now()), message: message }, null, message)
    }
    scrollChatToEnd()
    return true
  }
  // POSTs keep their IDs, so a retry after a lost response is never applied twice.
  function chatPost(route, body, next, draft) {
    var kind = chatKind, conversation = chatConversation, dns = chatDns
    chatSending = true
    api("POST", dns, route, body, function(res) {
      if (!sameChat(kind, conversation)) return
      if (!res.ok) {
        chatSending = false
        var retryable = res.code === 0 || res.code >= 500
        chatRetry = retryable ? { route: route, body: body, next: next, draft: draft } : null
        chatError = res.error === "busy" ? "The Keeper is still answering" : res.message
        if (!retryable) {
          if (draft && !chatInput.text) chatInput.text = draft
          chatPending = ""
          if (route === "keeper" || (route === "diggers/ask" && !chatRecord)) chatConversation = ""
        }
        return
      }
      chatRetry = null
      if (next) { next(); return }
      chatSending = false
      chatFollowUntil = Date.now() + 20000
      if (res.data && res.data.id) applyRecord(res.data)
      refreshChatList()
    })
  }
  function retryChat() {
    var retry = chatRetry
    if (!retry || chatSending) return
    chatRetry = null
    chatError = ""
    chatPost(retry.route, retry.body, retry.next, retry.draft)
  }
  function cancelChat() {
    if (!chatConversation || chatSending) return
    if (chatKind === "keeper") chatPost("keeper/cancel", { conversation: chatConversation }, null, "")
    else chatPost("diggers/cancel", { name: chatDigger, conversation: chatConversation, request: Model.newId(Date.now()) }, null, "")
  }
  function finishChat() {
    if (chatKind !== "digger" || !chatConversation || chatSending) return
    if (chatConfirm !== "finish") { chatConfirm = "finish"; return }
    chatConfirm = ""
    chatPost("diggers/finish", { name: chatDigger, conversation: chatConversation, request: Model.newId(Date.now()) }, null, "")
  }
  function resumeDigger(name) {
    var node = findNode(chatNodeId) || current
    if (!node || !Model.safeDiggerName(name)) return
    api("POST", node.dns, "diggers/resume", { name: name, request: Model.newId(Date.now()) }, function(res) {
      if (!res.ok) chatError = res.message
      root.refresh()
    })
  }
  function keeperHint() {
    var rows = current && current.keeper ? current.keeper.conversations : []
    if (rows.length && rows[0].state === "running") return "answering…"
    return "ask about this grave"
  }
  function diggerLabel(row) {
    var parts = [row.name, Model.diggerStatus(row)]
    var budget = Model.budgetLabel(row)
    if (budget) parts.push(budget)
    if (Model.diggerApprovals(row) > 0) parts.push(Model.diggerApprovals(row) + " approval" + (Model.diggerApprovals(row) === 1 ? "" : "s"))
    return parts.join(" · ")
  }

  // ---- Panel helpers ------------------------------------------------------------

  function fmt(value, suffix) {
    if (value === null || value === undefined || value === "") return "—"
    var parsed = Number(value)
    return isFinite(parsed) ? parsed.toFixed(1) + suffix : "—"
  }
  function resource(name) { return current && current.summary && current.summary.resources ? current.summary.resources[name] : null }
  function historyFor(name) {
    if (!current || !current.history) return []
    var values = []
    for (var i = 0; i < current.history.length; i++) { var value = Number(current.history[i][name]); if (isFinite(value)) values.push(value) }
    return values
  }
  function linkUrl(name) {
    var path = current && current.summary ? Model.safePath(current.summary.links[name]) : ""
    return current && path ? "https://" + current.dns + path : ""
  }
  function openLink(name) { var url = linkUrl(name); if (url) Qt.openUrlExternally(url) }
  function actionableT3Threads() { return Model.actionableT3Threads(current ? current.t3Activity : null, 5) }
  function openT3Thread(thread) {
    var url = current ? Model.activityUrl(current.dns, thread && thread.link) : ""
    if (url) Qt.openUrlExternally(url)
  }
  function hasPassageways() { return linkUrl("dashboard") !== "" || linkUrl("t3") !== "" || linkUrl("terminal") !== "" || linkUrl("network") !== "" }
  function openDashboard() {
    var url = linkUrl("dashboard")
    if (!url) return
    pendingDashboardUrl = url
    pendingDesktopEntry = desktopEntry
    if (!pendingDesktopEntry) { Qt.openUrlExternally(url); return }
    desktopCheck.command = ["grep", "--fixed-strings", "https://" + current.dns, Quickshell.env("HOME") + "/.local/share/applications/" + pendingDesktopEntry]
    desktopCheck.running = true
  }
  function inspectWebApp(raw) {
    var clients = []
    try { clients = JSON.parse(raw) } catch (_) {}
    var used = {}, match = null
    for (var i = 0; i < clients.length; i++) {
      var client = clients[i] || {}, workspace = client.workspace ? Number(client.workspace.id) : 0
      if (workspace > 0) used[workspace] = true
      var identity = String(client.class || "") + " " + String(client.initialClass || "") + " " + String(client.initialTitle || "")
      if (current && identity.indexOf(current.dns) >= 0 && identity.toLowerCase().indexOf("grave") >= 0) match = client
    }
    var address = match ? Model.safeHyprAddress(match.address) : ""
    if (address) {
      focusWebApp.command = ["hyprctl", "dispatch", "hl.dsp.focus({ window = \"address:" + address + "\" })"]
      focusWebApp.running = true
      return
    }
    pendingWorkspace = 1
    while (used[pendingWorkspace] && pendingWorkspace < 10) pendingWorkspace++
    switchWorkspace.command = ["hyprctl", "dispatch", "hl.dsp.focus({ workspace = \"" + String(pendingWorkspace) + "\" })"]
    switchWorkspace.running = true
  }
  function launchWebApp() { launchDesktop.command = ["gtk-launch", pendingDesktopEntry]; launchDesktop.running = true }

  onOpenedChanged: {
    if (!opened) return
    phraseIndex = 0
    refresh()
    if (Date.now() - pluginCheckedAt > 30 * 60 * 1000) checkPluginUpdate()
    if (chatOpen) { if (chatConversation) loadConversation(); focusChatInput() }
    else Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }
  Timer { interval: root.refreshIntervalSec * 1000; running: true; repeat: true; triggeredOnStart: true; onTriggered: root.refresh() }
  Timer { interval: 1000; running: root.opened; repeat: true; onTriggered: root.nowMs = Date.now() }
  Timer { interval: 12000; running: root.opened; repeat: true; onTriggered: root.phraseIndex++ }
  // Keeps following a running turn while the panel is closed, to notify when it settles.
  Timer { interval: 1500; running: root.chatOpen && root.chatConversation !== ""; repeat: true; onTriggered: if (Model.conversationBusy(root.chatRecord) || Date.now() < root.chatFollowUntil) root.loadConversation() }
  Timer { interval: 4000; running: Object.keys(root.upgrades).length > 0; repeat: true; onTriggered: root.pollUpgrades() }
  Timer { interval: 30000; running: root.updateChecks; onTriggered: root.checkPluginUpdate() }
  Timer { interval: 6 * 60 * 60 * 1000; running: root.updateChecks; repeat: true; onTriggered: root.checkPluginUpdate() }
  Process {
    id: status
    stdout: StdioCollector { id: statusOut; waitForEnd: true }
    onExited: function(code) { if (code === 0) root.parseStatus(String(statusOut.text || "")); else root.finishDiscovery() }
  }
  Process {
    id: probeProc
    stdout: StdioCollector { id: probeOut; waitForEnd: true }
    onExited: function(code) { root.recordProbe(code === 0 ? Model.probe(String(probeOut.text || "")) : null); root.probeNext() }
  }
  Process {
    id: releaseProc
    stdout: StdioCollector { id: releaseOut; waitForEnd: true }
    onExited: function(code) { root.recordReleases(code === 0 ? String(releaseOut.text || "") : "") }
  }
  Process {
    id: apiProc
    stdinEnabled: true
    stdout: StdioCollector { id: apiOut; waitForEnd: true }
    onStarted: if (root.apiCurrent && root.apiCurrent.body !== null) write(JSON.stringify(root.apiCurrent.body) + "\n")
    onExited: function(code) { root.apiFinished(String(apiOut.text || ""), code) }
  }
  Process {
    id: selfCheck
    stdout: StdioCollector { id: selfCheckOut; waitForEnd: true }
    onExited: function(code) { var info = code === 0 ? Model.pluginUpdate(String(selfCheckOut.text || "")) : null; if (info) root.pluginUpdate = info }
  }
  Process { id: notify }
  Process { id: desktopCheck; onExited: function(code) { if (code !== 0) { Qt.openUrlExternally(root.pendingDashboardUrl); return }; hyprClients.command = ["hyprctl", "clients", "-j"]; hyprClients.running = true } }
  Process {
    id: hyprClients
    stdout: StdioCollector { id: hyprClientsOut; waitForEnd: true }
    onExited: function(code) { if (code === 0) root.inspectWebApp(String(hyprClientsOut.text || "")); else root.launchWebApp() }
  }
  Process { id: focusWebApp }
  Process { id: launchDesktop; onExited: function(code) { if (code !== 0) Qt.openUrlExternally(root.pendingDashboardUrl) } }
  Process { id: switchWorkspace; onExited: root.launchWebApp() }

  IpcHandler {
    target: root.ipcTarget
    function open(): void { root.open() }
    function close(): void { root.close() }
    function toggle(): void { root.toggle() }
    function refresh(): string { root.refresh(); return "ok" }
    function dashboard(): string { root.openDashboard(); return "ok" }
    function keeper(): string { if (!root.currentHasKeeper) return "no keeper on the selected grave"; root.openChat("keeper", ""); root.open(); return "ok" }
    function checkUpdates(): string { root.checkPluginUpdate(); root.queueReleaseChecks(root.current ? root.current.id : ""); return "checking" }
    function status(): string {
      var base = root.nodes.length + " graves · " + root.reachableCount + " reachable"
      return base + " · " + root.fleetT3Feeds + " T3 feed" + (root.fleetT3Feeds === 1 ? "" : "s") + " · " + root.fleetT3Working + " working · " + root.fleetT3Attention + " need you"
        + " · " + root.fleetApprovals + " digger approvals · " + root.fleetUpdates + " grave updates" + (root.pluginUpdateAvailable ? " · plugin update" : "")
    }
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    iconComponent: Component { GraveIcon { iconSize: Style.font.icon; fontFamily: root.fontFamily; color: root.nodes.length ? (root.warningCount > 0 || root.fleetT3Attention > 0 || root.fleetApprovals > 0 ? root.urgent : root.foreground) : root.dim; badgeCount: root.warningCount + root.fleetT3Attention + root.fleetApprovals; breathing: root.refreshing || root.fleetT3Working > 0 || root.chatBusy } }
    tooltipText: {
      if (!root.nodes.length) return root.refreshing ? "Gravedecay · checking beneath the soil" : "Gravedecay · no graves found"
      var parts = ["Gravedecay · " + root.reachableCount + "/" + root.nodes.length + " reachable"]
      if (root.warningCount) parts.push(root.warningCount + " restless")
      if (root.fleetT3Working) parts.push(root.fleetT3Working + " T3 working")
      if (root.fleetT3Attention) parts.push(root.fleetT3Attention + " need you")
      if (root.fleetApprovals) parts.push(root.fleetApprovals + " digger approval" + (root.fleetApprovals === 1 ? "" : "s"))
      if (root.fleetUpdates) parts.push(root.fleetUpdates + " grave update" + (root.fleetUpdates === 1 ? "" : "s"))
      if (root.pluginUpdateAvailable) parts.push("plugin update")
      if (parts.length === 1) parts.push("buried, not broken")
      return parts.join(" · ")
    }
    onPressed: function(code) { if (code === Qt.RightButton || code === Qt.MiddleButton) root.refresh(); else root.toggle() }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: root.chatOpen ? chatInput : keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(420))
    contentHeight: panel.fittedContentHeight(content.implicitHeight, Style.space(660))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      blocked: chatInput.activeFocus
      onMoveRequested: function(dx, dy) {
        if (dx && !root.chatOpen) root.selectRelative(dx)
        if (dy) panelFlick.contentY = Model.clamp(panelFlick.contentY + dy * Style.space(54), 0, Math.max(0, panelFlick.contentHeight - panelFlick.height))
      }
      onActivateRequested: { if (root.chatOpen) root.focusChatInput(); else root.openDashboard() }
      onCloseRequested: { if (root.chatOpen) root.closeChat(); else root.close() }
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(text) {
        if (root.chatOpen) { chatInput.text += text; root.focusChatInput(); return }
        if (text === "r" || text === "R") { root.refresh(); root.queueReleaseChecks(root.current ? root.current.id : "") }
        else if (text === "d" || text === "D") root.openDashboard()
        else if ((text === "g" || text === "G") && root.currentHasKeeper) root.openChat("keeper", "")
      }

      Flickable {
        id: panelFlick
        anchors.fill: parent
        contentWidth: width
        contentHeight: content.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        interactive: contentHeight > height
        ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

        Column {
          id: content
          width: panelFlick.width
          spacing: Style.space(12)

          // ---- Overview ----
          Column {
            visible: !root.chatOpen
            width: parent.width
            spacing: Style.space(12)

            PanelHero {
              width: parent.width
              title: root.current ? (root.current.summary.node.host || root.current.name) : "Gravedecay"
              meta: root.current ? String(root.current.summary.node.platform || "unknown") + " · " + String(root.current.summary.node.mode || "unknown") : (root.refreshing ? "DISCOVERING THE TAILNET" : "NO APPLIANCES REACHABLE")
              detail: root.current ? Model.stateLabel(root.current) : ""
              foreground: root.stateColor
              fontFamily: root.fontFamily
              iconComponent: Component { GraveIcon { iconSize: Style.font.display; fontFamily: root.fontFamily; color: root.stateColor; breathing: root.refreshing || root.currentT3Counts.working > 0 } }
              trailingControl: Component { PanelActionButton { iconText: "󰑐"; tooltipText: "Refresh graves"; foreground: root.foreground; fontFamily: root.fontFamily; onClicked: { root.refresh(); root.queueReleaseChecks(root.current ? root.current.id : "") } } }
            }

            RowLayout {
              visible: root.nodes.length > 1
              width: parent.width
              spacing: Style.space(8)
              Dropdown { id: nodePicker; Layout.fillWidth: true; showLabel: false; options: root.nodes.map(function(node) { var r = root.releases[node.id]; return { value: node.id, label: (node.reachable ? "" : "☠ ") + node.name + (r && r.info && r.info.latest ? "  󰚰" : "") } }); onChanged: function(value) { root.selectedId = value; root.phraseIndex = 0; root.confirmUpgradeId = "" }; Connections { target: root; function onSelectedIdChanged() { nodePicker.value = root.selectedId } } }
              Text { text: root.reachableCount + "/" + root.nodes.length + " awake"; color: root.dim; font.family: root.fontFamily; font.pixelSize: Style.font.caption }
            }

            Text { visible: !root.current; width: parent.width; topPadding: Style.space(24); bottomPadding: Style.space(24); text: root.refreshing ? "Checking beneath the soil…" : "No Gravedecay appliances answered on this tailnet."; color: root.dim; font.family: root.fontFamily; font.pixelSize: Style.font.body; horizontalAlignment: Text.AlignHCenter; wrapMode: Text.WordWrap }

            Column {
              visible: !!root.current
              width: parent.width
              spacing: Style.space(10)
              PanelSeparator { width: parent.width; foreground: root.foreground }
              PanelSectionHeader { text: "VITALS"; foreground: root.foreground; fontFamily: root.fontFamily }
              Metric { width: parent.width; icon: "󰍛"; label: "CPU"; value: root.resource("cpu_pct"); display: root.fmt(value, "%"); history: root.historyFor("cpu") }
              Metric { width: parent.width; icon: "󰘚"; label: "Memory"; value: root.resource("memory_pct"); display: root.fmt(value, "%"); history: root.historyFor("memory") }
              Metric { width: parent.width; icon: "󰋊"; label: "Disk"; value: root.resource("disk_pct"); display: root.fmt(value, "%"); history: root.historyFor("disk") }

              PanelSeparator { width: parent.width; foreground: root.foreground }
              PanelSectionHeader { text: "ACTIVITY & HEALTH"; foreground: root.foreground; fontFamily: root.fontFamily }
              GridLayout {
                width: parent.width; columns: 2; columnSpacing: Style.space(8); rowSpacing: Style.space(8)
                StatCard { Layout.fillWidth: true; icon: "󰖟"; label: "CLI sessions"; value: root.current ? String(root.current.summary.activity.sessions_live || 0) : "—" }
                StatCard { Layout.fillWidth: true; icon: "󰤄"; label: "Frozen"; value: root.current ? String(root.current.summary.activity.sessions_frozen || 0) : "—" }
                StatCard { visible: root.currentT3Available; Layout.fillWidth: true; icon: "󰚩"; label: "T3 working"; value: String(root.currentT3Counts.working) }
                StatCard { visible: root.currentT3Available; Layout.fillWidth: true; icon: "󰀦"; label: "Needs you"; value: String(root.currentT3Counts.attention); alarming: Number(value) > 0 }
                StatCard { Layout.fillWidth: true; icon: "󰒋"; label: "Failed services"; value: root.current ? String(root.current.summary.health.services_failed || 0) : "—"; alarming: Number(value) > 0 }
                StatCard { Layout.fillWidth: true; icon: "󰡨"; label: "Containers"; value: root.current ? String(root.current.summary.health.containers_problem || 0) : "—"; alarming: Number(value) > 0 }
              }

              Column {
                visible: root.currentT3Available && root.actionableT3Threads().length > 0
                width: parent.width
                spacing: Style.space(6)
                PanelSeparator { width: parent.width; foreground: root.foreground }
                PanelSectionHeader { text: root.current && root.current.t3Activity && root.current.t3Activity.status === "stale" ? "T3 CHAT ACTIVITY · STALE" : "T3 CHAT ACTIVITY"; foreground: root.foreground; fontFamily: root.fontFamily }
                Repeater {
                  model: root.actionableT3Threads()
                  delegate: Button {
                    required property var modelData
                    width: parent.width
                    text: String(modelData.project || "project") + " · " + String(modelData.title || "thread") + " · " + String(modelData.phase || "").replace(/_/g, " ")
                    iconText: modelData.phase === "waiting_approval" || modelData.phase === "waiting_input" ? "󰀦" : modelData.phase === "failed" ? "󰅙" : "󰚩"
                    bordered: true
                    foreground: modelData.phase === "failed" ? root.urgent : root.foreground
                    fontFamily: root.fontFamily
                    onClicked: root.openT3Thread(modelData)
                  }
                }
              }

              Column {
                visible: root.currentHasKeeper || root.currentDiggers.length > 0
                width: parent.width
                spacing: Style.space(6)
                PanelSeparator { width: parent.width; foreground: root.foreground }
                PanelSectionHeader { text: "KEEPER & DIGGERS"; foreground: root.foreground; fontFamily: root.fontFamily }
                Button {
                  visible: root.currentHasKeeper
                  width: parent.width
                  leftAlign: true
                  text: "Gravekeeper · " + (root.currentCaps && root.currentCaps.keeper ? root.currentCaps.keeper.provider : "") + " · " + root.keeperHint()
                  iconText: "󰊠"
                  tooltipText: "Talk to this grave's Keeper (g)"
                  bordered: true
                  foreground: root.foreground
                  fontFamily: root.fontFamily
                  onClicked: root.openChat("keeper", "")
                }
                Repeater {
                  model: root.currentDiggers
                  delegate: Button {
                    required property var modelData
                    width: parent.width
                    leftAlign: true
                    text: root.diggerLabel(modelData)
                    iconText: "󰜐"
                    tooltipText: modelData.repo ? modelData.provider + " · " + modelData.repo : modelData.provider
                    bordered: true
                    foreground: Model.diggerNeedsAttention(modelData) ? root.urgent : modelData.enabled ? root.foreground : root.dim
                    fontFamily: root.fontFamily
                    onClicked: root.openChat("digger", modelData.name)
                  }
                }
              }

              PanelSeparator { width: parent.width; foreground: root.foreground }
              PanelSectionHeader { text: "SYSTEM"; foreground: root.foreground; fontFamily: root.fontFamily }
              RowLayout {
                width: parent.width; spacing: Style.space(12)
                SystemFact { Layout.fillWidth: true; label: "UPTIME"; value: root.current ? Model.formatDuration(root.current.summary.node.uptime_s) : "—" }
                SystemFact { Layout.fillWidth: true; label: "CPU TEMP"; value: root.fmt(root.resource("cpu_temp_c"), "°C") }
                SystemFact { Layout.fillWidth: true; label: "GPU TEMP"; value: root.fmt(root.resource("gpu_temp_c"), "°C") }
              }
              Text { width: parent.width; text: root.current ? (root.current.reachable ? "Observed " + Model.formatAge(root.current.summary.observed_at, root.nowMs) : "Last answered " + Model.formatAge(root.current.lastSeen, root.nowMs)) : ""; color: root.dim; font.family: root.fontFamily; font.pixelSize: Style.font.caption; horizontalAlignment: Text.AlignRight }

              Column {
                visible: !!root.currentRelease || !!root.currentUpgrade
                width: parent.width
                spacing: Style.space(6)
                PanelSeparator { width: parent.width; foreground: root.foreground }
                PanelSectionHeader { text: "GRAVE UPDATE"; foreground: root.foreground; fontFamily: root.fontFamily }
                Text {
                  width: parent.width
                  wrapMode: Text.WordWrap
                  textFormat: Text.PlainText
                  readonly property var info: root.currentRelease ? root.currentRelease.info : null
                  text: !info ? "" : Model.releaseLabel(info) + (info.latest ? " · " + info.latest + " is available"
                    : info.current ? " · up to date"
                    : info.newestRelease ? " · newest release " + info.newestRelease : "")
                  color: info && info.latest ? root.foreground : root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.body
                }
                RowLayout {
                  // A grave on a branch or commit is offered the newest release too, but
                  // never counted as "behind" since its checkout may be newer.
                  readonly property var info: root.currentRelease ? root.currentRelease.info : null
                  readonly property bool offCheckout: !!info && !info.latest && !info.current && !info.native
                  readonly property string tag: !info ? "" : info.latest || (offCheckout ? info.newestRelease : "")
                  visible: tag !== "" && !!root.currentCaps && root.currentCaps.upgrade && root.current.reachable && !root.upgradeActive(root.current.id)
                  width: parent.width
                  spacing: Style.space(6)
                  Button {
                    Layout.fillWidth: true
                    readonly property bool confirming: root.current && root.confirmUpgradeId === root.current.id
                    text: confirming ? "Confirm: " + (parent.offCheckout ? "switch " : "update ") + root.current.name + " to " + parent.tag
                      : parent.offCheckout ? "Switch grave to release " + parent.tag : "Update grave to " + parent.tag
                    iconText: "󰚰"
                    tooltipText: parent.offCheckout ? "Leaves " + Model.releaseLabel(parent.info) + " for the release; the dashboard restarts while it updates" : "The grave restarts its dashboard while it updates"
                    bordered: true
                    foreground: confirming ? root.urgent : parent.offCheckout ? root.dim : root.foreground
                    fontFamily: root.fontFamily
                    onClicked: { if (confirming) root.startUpgrade(root.current, parent.tag); else root.confirmUpgradeId = root.current.id }
                  }
                  Button { visible: root.current && root.confirmUpgradeId === root.current.id; text: "Cancel"; bordered: true; foreground: root.foreground; fontFamily: root.fontFamily; onClicked: root.confirmUpgradeId = "" }
                }
                Text {
                  visible: !!root.currentUpgrade
                  width: parent.width
                  wrapMode: Text.WordWrap
                  textFormat: Text.PlainText
                  text: root.currentUpgrade ? root.currentUpgrade.message : ""
                  color: root.currentUpgrade && (root.currentUpgrade.state === "failed" || root.currentUpgrade.state === "unknown") ? root.urgent : root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                }
              }

              Column {
                visible: root.hasPassageways()
                width: parent.width
                spacing: Style.space(10)
                PanelSeparator { width: parent.width; foreground: root.foreground }
                PanelSectionHeader { text: "PASSAGEWAYS"; foreground: root.foreground; fontFamily: root.fontFamily }
                RowLayout {
                  width: parent.width; spacing: Style.space(6)
                  Button { visible: root.linkUrl("dashboard") !== ""; Layout.fillWidth: true; text: "Dashboard"; iconText: "󰖟"; bordered: true; foreground: root.foreground; fontFamily: root.fontFamily; onClicked: root.openDashboard() }
                  Button { visible: root.linkUrl("t3") !== ""; Layout.fillWidth: true; text: "T3"; iconText: "󰚩"; bordered: true; foreground: root.foreground; fontFamily: root.fontFamily; onClicked: root.openLink("t3") }
                  Button { visible: root.linkUrl("terminal") !== ""; Layout.fillWidth: true; text: "Terminal"; iconText: "󰆍"; bordered: true; foreground: root.foreground; fontFamily: root.fontFamily; onClicked: root.openLink("terminal") }
                  Button { visible: root.linkUrl("network") !== ""; Layout.fillWidth: true; text: "Network"; iconText: "󰛳"; bordered: true; foreground: root.foreground; fontFamily: root.fontFamily; onClicked: root.openLink("network") }
                }
              }
            }

            Column {
              visible: root.pluginUpdateAvailable || (!!root.pluginUpdate && !root.pluginUpdate.git)
              width: parent.width
              spacing: Style.space(6)
              PanelSeparator { width: parent.width; foreground: root.foreground }
              RowLayout {
                width: parent.width
                spacing: Style.space(8)
                Text { Layout.fillWidth: true; text: Model.pluginUpdateLabel(root.pluginUpdate); wrapMode: Text.WordWrap; textFormat: Text.PlainText; color: root.pluginUpdateAvailable ? root.foreground : root.dim; font.family: root.fontFamily; font.pixelSize: Style.font.caption }
                Button { visible: root.pluginUpdateAvailable; text: "Review & update"; iconText: "󰅢"; tooltipText: "Opens a terminal with the incoming changes before anything is applied"; bordered: true; foreground: root.foreground; fontFamily: root.fontFamily; onClicked: root.applyPluginUpdate() }
              }
            }

            Text { width: parent.width; topPadding: Style.space(3); text: root.phrase.toUpperCase(); color: root.currentState === "warning" ? root.urgent : root.dim; font.family: root.fontFamily; font.pixelSize: Style.font.caption; font.bold: true; font.letterSpacing: 1.2; horizontalAlignment: Text.AlignHCenter }
            Text { width: parent.width; text: "←/→ changes grave · g keeper · r exhumes · enter opens · esc buries"; color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.35); font.family: root.fontFamily; font.pixelSize: Style.font.caption; horizontalAlignment: Text.AlignHCenter }
          }

          // ---- Conversation ----
          Column {
            visible: root.chatOpen
            width: parent.width
            spacing: Style.space(10)

            RowLayout {
              width: parent.width
              spacing: Style.space(8)
              PanelActionButton { iconText: "󰁍"; tooltipText: "Back (esc)"; foreground: root.foreground; fontFamily: root.fontFamily; onClicked: root.closeChat() }
              Text { text: root.chatKind === "keeper" ? "󰊠" : "󰜐"; color: root.chatError ? root.urgent : root.foreground; font.family: root.fontFamily; font.pixelSize: Style.font.title; opacity: root.chatBusy ? 0.6 : 1 }
              ColumnLayout {
                Layout.fillWidth: true
                spacing: Style.space(1)
                Text { Layout.fillWidth: true; text: root.chatKind === "keeper" ? "GRAVEKEEPER" : root.chatDigger.toUpperCase(); color: root.foreground; font.family: root.fontFamily; font.pixelSize: Style.font.heading; font.bold: true; font.letterSpacing: 1.2; elide: Text.ElideRight }
                Text {
                  Layout.fillWidth: true
                  textFormat: Text.PlainText
                  elide: Text.ElideRight
                  text: {
                    var parts = [root.chatHost]
                    if (root.chatKind === "digger" && root.chatDiggerRow) { parts.push(Model.diggerStatus(root.chatDiggerRow)); var b = Model.budgetLabel(root.chatDiggerRow); if (b) parts.push(b) }
                    parts.push(Model.conversationStateLabel(root.chatRecord))
                    return parts.join(" · ")
                  }
                  color: root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                }
              }
            }

            Dropdown {
              id: conversationPicker
              width: parent.width
              showLabel: false
              options: root.conversationOptions()
              value: root.chatConversation
              onChanged: function(value) { root.selectConversation(value) }
            }

            RowLayout {
              visible: root.chatKind === "digger" && !!root.chatDiggerRow && (root.chatDiggerRow.pause === "budget" || Model.diggerApprovals(root.chatDiggerRow) > 0 || root.chatDiggerRow.loggedIn === false)
              width: parent.width
              spacing: Style.space(8)
              Text {
                Layout.fillWidth: true
                wrapMode: Text.WordWrap
                textFormat: Text.PlainText
                text: !root.chatDiggerRow ? "" : root.chatDiggerRow.loggedIn === false ? "Signed out · run grave digger login " + root.chatDigger + " on the grave"
                  : root.chatDiggerRow.pause === "budget" ? "Paused by its budget" + (root.chatDiggerRow.budgetReason ? " · " + root.chatDiggerRow.budgetReason : "")
                  : Model.diggerApprovals(root.chatDiggerRow) + " approval(s) waiting in Slack"
                color: root.urgent
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
              }
              Button { visible: !!root.chatDiggerRow && root.chatDiggerRow.pause === "budget"; text: "Resume"; iconText: "󰐊"; tooltipText: "Restart today's budget window"; bordered: true; foreground: root.foreground; fontFamily: root.fontFamily; onClicked: root.resumeDigger(root.chatDigger) }
            }

            PanelSeparator { width: parent.width; foreground: root.foreground }

            Text {
              visible: root.chatLines.length === 0 && !root.chatPending && !root.chatLoading
              width: parent.width
              topPadding: Style.space(8)
              bottomPadding: Style.space(8)
              wrapMode: Text.WordWrap
              textFormat: Text.PlainText
              text: root.chatKind === "keeper"
                ? "Ask the Keeper about " + root.chatHost + ": health, logs, services, backups. It reads live resources and can run grave doctor."
                : "Ask " + root.chatDigger + " to do its job" + (root.chatDiggerRow && root.chatDiggerRow.repo ? " in " + root.chatDiggerRow.repo : "") + ". It works on its own branch; Finish packages the result."
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
              horizontalAlignment: Text.AlignHCenter
            }

            Repeater {
              model: root.chatLines
              delegate: ChatLine {
                required property var modelData
                width: parent.width
                role: modelData.role
                label: modelData.label
                body: modelData.text
              }
            }

            ChatLine {
              visible: root.chatPending !== ""
              width: parent.width
              role: "owner"
              label: root.chatSending ? "YOU · SENDING" : root.chatRecord && root.chatRecord.state === "queued" ? "YOU · QUEUED" : "YOU"
              body: root.chatPending
              opacity: 0.7
            }

            Text {
              visible: root.chatBusy && !root.chatSending
              width: parent.width
              text: (root.chatKind === "keeper" ? "The Keeper" : root.chatDigger) + (root.chatRecord && root.chatRecord.state === "queued" ? " has your request in its queue…" : root.chatRecord && root.chatRecord.phase === "finishing" ? " is packaging the result…" : " is digging…")
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              font.italic: true
              SequentialAnimation on opacity {
                running: root.chatBusy && root.opened
                loops: Animation.Infinite
                NumberAnimation { to: 0.4; duration: 600; easing.type: Easing.InOutQuad }
                NumberAnimation { to: 1; duration: 600; easing.type: Easing.InOutQuad }
              }
            }

            BorderSurface {
              visible: !!root.chatRecord && !!root.chatRecord.result
              width: parent.width
              implicitHeight: resultColumn.implicitHeight + Style.spacing.xl
              color: Style.selectedFillFor(root.foreground, Color.accent)
              borderSpec: Border.controlSpec("normal", root.foreground, Color.accent)
              radius: Style.cornerRadius
              Column {
                id: resultColumn
                anchors.left: parent.left; anchors.right: parent.right; anchors.verticalCenter: parent.verticalCenter
                anchors.leftMargin: Style.space(10); anchors.rightMargin: Style.space(10)
                spacing: Style.space(3)
                Text { width: parent.width; text: "RESULT · " + String(root.chatRecord && root.chatRecord.result ? root.chatRecord.result.verdict || "done" : "").toUpperCase() + (root.chatRecord && root.chatRecord.branch ? " · " + root.chatRecord.branch : ""); textFormat: Text.PlainText; elide: Text.ElideRight; color: root.foreground; font.family: root.fontFamily; font.pixelSize: Style.font.caption; font.bold: true }
                Text { width: parent.width; visible: text !== ""; text: root.chatRecord && root.chatRecord.result ? root.chatRecord.result.summary : ""; textFormat: Text.PlainText; wrapMode: Text.WordWrap; color: root.foreground; font.family: root.fontFamily; font.pixelSize: Style.font.body }
              }
            }

            RowLayout {
              visible: root.chatError !== ""
              width: parent.width
              spacing: Style.space(8)
              Text { Layout.fillWidth: true; text: root.chatError; wrapMode: Text.WordWrap; textFormat: Text.PlainText; color: root.urgent; font.family: root.fontFamily; font.pixelSize: Style.font.caption }
              Button { visible: !!root.chatRetry; text: "Retry"; iconText: "󰑐"; bordered: true; foreground: root.foreground; fontFamily: root.fontFamily; onClicked: root.retryChat() }
            }

            Flow {
              visible: root.chatKind === "digger" && !!root.chatDiggerRow && root.chatDiggerRow.prompts.length > 0
              width: parent.width
              spacing: Style.space(6)
              Repeater {
                model: root.chatDiggerRow ? root.chatDiggerRow.prompts : []
                delegate: Button {
                  required property var modelData
                  text: modelData.label
                  tooltipText: modelData.template
                  bordered: true
                  foreground: root.foreground
                  fontFamily: root.fontFamily
                  fontSize: Style.font.caption
                  onClicked: { chatInput.text = modelData.template; root.focusChatInput() }
                }
              }
            }

            RowLayout {
              width: parent.width
              spacing: Style.space(6)
              TextField {
                id: chatInput
                Layout.fillWidth: true
                foreground: root.foreground
                font.family: root.fontFamily
                maximumLength: 8000
                enabled: !root.chatSending
                placeholderText: root.chatKind === "keeper" ? (Model.conversationBusy(root.chatRecord) ? "The Keeper is answering…" : "Ask the Keeper…") : "Ask " + root.chatDigger + "…"
                onAccepted: if (root.sendChat(text)) text = ""
                Keys.onEscapePressed: function(event) { keyCatcher.forceActiveFocus(); event.accepted = true }
              }
              Button {
                iconText: "󰒊"
                tooltipText: "Send (enter)"
                bordered: true
                foreground: root.foreground
                fontFamily: root.fontFamily
                onClicked: if (root.sendChat(chatInput.text)) chatInput.text = ""
              }
            }

            RowLayout {
              visible: root.chatConversation !== ""
              width: parent.width
              spacing: Style.space(6)
              Button { visible: root.chatBusy && !root.chatSending; Layout.fillWidth: true; text: "Stop"; iconText: "󰓛"; bordered: true; foreground: root.urgent; fontFamily: root.fontFamily; onClicked: root.cancelChat() }
              Button {
                visible: root.chatKind === "digger" && !!root.chatRecord && root.chatRecord.phase === "open" && root.chatRecord.state !== "queued"
                Layout.fillWidth: true
                text: root.chatConfirm === "finish" ? "Confirm finish" : "Finish"
                iconText: "󰈑"
                tooltipText: "End the conversation and package the result"
                bordered: true
                foreground: root.chatConfirm === "finish" ? root.urgent : root.foreground
                fontFamily: root.fontFamily
                onClicked: root.finishChat()
              }
              Button { Layout.fillWidth: true; text: "New"; iconText: "󰐕"; tooltipText: "Start a new conversation"; bordered: true; foreground: root.foreground; fontFamily: root.fontFamily; onClicked: root.selectConversation("") }
            }

            Text { width: parent.width; text: "enter sends · esc leaves the field, then goes back"; color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.35); font.family: root.fontFamily; font.pixelSize: Style.font.caption; horizontalAlignment: Text.AlignHCenter }
          }
        }
      }
    }
  }

  component ChatLine: Column {
    id: line
    property string role: "agent"
    property string label: ""
    property string body: ""
    spacing: Style.space(2)
    Text {
      visible: line.label !== ""
      text: line.label
      textFormat: Text.PlainText
      color: line.role === "error" ? root.urgent : line.role === "owner" ? root.foreground : root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      font.bold: true
      font.letterSpacing: 1.1
    }
    TextEdit {
      width: parent.width
      text: line.body
      textFormat: TextEdit.PlainText
      readOnly: true
      selectByMouse: true
      activeFocusOnPress: false
      wrapMode: TextEdit.Wrap
      color: line.role === "error" ? root.urgent : line.role === "tool" || line.role === "note" ? root.dim : root.foreground
      selectionColor: root.track
      selectedTextColor: root.foreground
      font.family: root.fontFamily
      font.pixelSize: line.role === "tool" ? Style.font.caption : Style.font.body
    }
  }
  component Metric: Column {
    id: metric
    property string icon: ""
    property string label: ""
    property real value: -1
    property string display: "—"
    property var history: []
    spacing: Style.space(5)
    RowLayout {
      width: parent.width
      Text { text: metric.icon; color: root.foreground; font.family: root.fontFamily; font.pixelSize: Style.font.body }
      Text { text: metric.label; color: root.foreground; font.family: root.fontFamily; font.pixelSize: Style.font.body; Layout.fillWidth: true }
      Text { text: metric.display; color: metric.value >= 90 ? root.urgent : root.foreground; font.family: root.fontFamily; font.pixelSize: Style.font.caption; font.bold: true }
    }
    Item {
      width: parent.width; height: Style.space(20)
      Rectangle { anchors.left: parent.left; anchors.right: spark.left; anchors.rightMargin: Style.space(10); anchors.verticalCenter: parent.verticalCenter; height: Math.max(Style.space(4), Math.round(Style.spacing.controlHeight * 0.14)); radius: height / 2; color: root.track; Rectangle { width: parent.width * Model.clamp(metric.value, 0, 100) / 100; height: parent.height; radius: parent.radius; color: metric.value >= 90 ? root.urgent : root.foreground; Behavior on width { NumberAnimation { duration: 220; easing.type: Easing.OutCubic } } } }
      Sparkline { id: spark; anchors.right: parent.right; anchors.verticalCenter: parent.verticalCenter; width: Style.space(72); height: Style.space(20); values: metric.history; lineColor: metric.value >= 90 ? root.urgent : root.foreground }
    }
  }
  component Sparkline: Canvas {
    id: chart
    property var values: []
    property color lineColor: root.foreground
    onValuesChanged: requestPaint()
    onLineColorChanged: requestPaint()
    onPaint: {
      var ctx = getContext("2d"); ctx.reset(); if (!values || values.length < 2) return
      ctx.strokeStyle = lineColor; ctx.globalAlpha = 0.75; ctx.lineWidth = Math.max(1, Style.scale); ctx.beginPath()
      for (var i = 0; i < values.length; i++) { var x = i * width / Math.max(1, values.length - 1), y = height - Model.clamp(values[i], 0, 100) * height / 100; if (i === 0) ctx.moveTo(x, y); else ctx.lineTo(x, y) }
      ctx.stroke()
    }
  }
  component StatCard: BorderSurface {
    id: stat
    property string icon: ""
    property string label: ""
    property string value: "—"
    property bool alarming: false
    implicitHeight: inner.implicitHeight + Style.spacing.xl
    color: Style.selectedFillFor(root.foreground, Color.accent)
    borderSpec: Border.controlSpec("normal", root.foreground, Color.accent)
    radius: Style.cornerRadius
    RowLayout {
      id: inner
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      anchors.leftMargin: Style.space(10)
      anchors.rightMargin: Style.space(10)
      spacing: Style.space(8)
      Text { text: stat.icon; color: stat.alarming ? root.urgent : root.dim; font.family: root.fontFamily; font.pixelSize: Style.font.heading }
      ColumnLayout {
        Layout.fillWidth: true
        spacing: Style.space(1)
        Text { text: stat.value; color: stat.alarming ? root.urgent : root.foreground; font.family: root.fontFamily; font.pixelSize: Style.font.title; font.bold: true }
        Text { text: stat.label; color: root.dim; font.family: root.fontFamily; font.pixelSize: Style.font.caption; elide: Text.ElideRight; Layout.fillWidth: true }
      }
    }
  }
  component SystemFact: ColumnLayout {
    property string label: ""
    property string value: "—"
    spacing: Style.space(2)
    Text { text: parent.label; color: root.dim; font.family: root.fontFamily; font.pixelSize: Style.font.caption; font.bold: true }
    Text { text: parent.value; color: root.foreground; font.family: root.fontFamily; font.pixelSize: Style.font.body; font.bold: true }
  }
}
