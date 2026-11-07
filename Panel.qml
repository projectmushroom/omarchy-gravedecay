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

  property var nodes: []
  property string selectedId: ""
  property bool refreshing: false
  property var pending: []
  property var discovered: []
  property var probing: null
  property var probingSummary: null
  property bool completedInitialScan: false
  property double nowMs: Date.now()
  property int phraseIndex: 0
  property string pendingDashboardUrl: ""
  property string pendingDesktopEntry: ""
  property int pendingWorkspace: 1

  readonly property int refreshIntervalSec: Math.round(Model.clamp(settings && settings.refreshIntervalSec !== undefined ? settings.refreshIntervalSec : 45, 30, 300))
  readonly property bool notificationsEnabled: settings && settings.notificationsEnabled === true
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
  readonly property int reachableCount: countWhere(function(node) { return node.reachable !== false })
  readonly property int warningCount: countWhere(function(node) { var s = Model.state(node); return s === "warning" || s === "unreachable" })
  readonly property int fleetT3Feeds: countWhere(function(node) { return Model.t3Available(node.t3Activity) })
  readonly property int fleetT3Working: t3Total("working")
  readonly property int fleetT3Attention: t3Total("attention")
  readonly property string phrase: {
    if (!current) return refreshing ? "Knocking on crypts" : "No graves found on this tailnet"
    var phrases = Model.phraseBucket(current)
    return phrases[phraseIndex % phrases.length]
  }
  readonly property color stateColor: currentT3Counts.attention > 0 || currentState === "warning" ? urgent : currentState === "unreachable" ? dim : foreground

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  function findNode(id) {
    for (var i = 0; i < nodes.length; i++) if (String(nodes[i].id) === String(id)) return nodes[i]
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
  function nodeIndex(node) {
    if (!node) return 0
    for (var i = 0; i < nodes.length; i++) if (nodes[i].id === node.id) return i
    return 0
  }
  function selectRelative(delta) {
    if (!nodes.length) return
    selectedId = nodes[(nodeIndex(current) + delta + nodes.length) % nodes.length].id
    phraseIndex = 0
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
  function probeNext() {
    if (!pending.length) { finishDiscovery(); return }
    probing = pending.shift()
    probingSummary = null
    curl.command = ["curl", "--silent", "--show-error", "--fail", "--connect-timeout", "2", "--max-time", "3", "--max-filesize", "65536", "https://" + probing.dns + "/grave/api/v1/summary"]
    curl.running = true
  }
  function recordSummaryProbe(value) {
    var old = previousNode(probing.id)
    if (!value) {
      if (old) discovered.push({ id: old.id, dns: old.dns, name: old.name, reachable: false, lastSeen: old.lastSeen, summary: old.summary, t3Activity: old.t3Activity || null, history: old.history || [] })
      return false
    }
    probingSummary = value
    activityCurl.command = ["curl", "--silent", "--show-error", "--fail", "--connect-timeout", "2", "--max-time", "3", "--max-filesize", "131072", "https://" + probing.dns + "/grave/api/t3-activity"]
    activityCurl.running = true
    return true
  }
  function recordActivityProbe(value) {
    var old = previousNode(probing.id)
    discovered.push({ id: probing.id, dns: probing.dns, name: probing.name, reachable: true, lastSeen: Date.now(), summary: probingSummary, t3Activity: value, history: appendHistory(old, probingSummary) })
    probingSummary = null
  }
  function containsDiscovered(id) {
    for (var i = 0; i < discovered.length; i++) if (discovered[i].id === id) return true
    return false
  }
  function maybeNotify(oldNode, nextNode) {
    if (!completedInitialScan || !notificationsEnabled || !oldNode || notify.running) return
    var beforeT3 = Model.t3Counts(oldNode.t3Activity), afterT3 = Model.t3Counts(nextNode.t3Activity)
    if (afterT3.attention > beforeT3.attention) {
      var attention = afterT3.attention
      notify.command = ["notify-send", "--app-name=Gravedecay", "Gravedecay · " + nextNode.name, attention + " T3 chat" + (attention === 1 ? " needs" : "s need") + " you"]
      notify.running = true
      return
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
    notify.command = ["notify-send", "--app-name=Gravedecay", "Gravedecay · " + nextNode.name, body]
    notify.running = true
  }
  function finishDiscovery() {
    for (var i = 0; i < nodes.length; i++) {
      var old = nodes[i]
      if (!containsDiscovered(old.id)) discovered.push({ id: old.id, dns: old.dns, name: old.name, reachable: false, lastSeen: old.lastSeen, summary: old.summary, t3Activity: old.t3Activity || null, history: old.history || [] })
    }
    discovered.sort(function(a, b) { if (a.reachable !== b.reachable) return a.reachable ? -1 : 1; return String(a.name).localeCompare(String(b.name)) })
    for (var j = 0; j < discovered.length; j++) maybeNotify(previousNode(discovered[j].id), discovered[j])
    nodes = discovered.slice()
    if (nodes.length && !findNode(selectedId)) selectedId = nodes[0].id
    refreshing = false
    completedInitialScan = true
    phraseIndex = 0
  }
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

  onOpenedChanged: if (opened) { phraseIndex = 0; refresh(); Qt.callLater(function() { keyCatcher.forceActiveFocus() }) }
  Timer { interval: root.refreshIntervalSec * 1000; running: true; repeat: true; triggeredOnStart: true; onTriggered: root.refresh() }
  Timer { interval: 1000; running: root.opened; repeat: true; onTriggered: root.nowMs = Date.now() }
  Timer { interval: 12000; running: root.opened; repeat: true; onTriggered: root.phraseIndex++ }
  Process {
    id: status
    stdout: StdioCollector { id: statusOut; waitForEnd: true }
    onExited: function(code) { if (code === 0) root.parseStatus(String(statusOut.text || "")); else root.finishDiscovery() }
  }
  Process {
    id: curl
    stdout: StdioCollector { id: curlOut; waitForEnd: true }
    onExited: function(code) { if (!root.recordSummaryProbe(code === 0 ? Model.summary(String(curlOut.text || "")) : null)) root.probeNext() }
  }
  Process {
    id: activityCurl
    stdout: StdioCollector { id: activityCurlOut; waitForEnd: true }
    onExited: function(code) { root.recordActivityProbe(code === 0 ? Model.t3Activity(String(activityCurlOut.text || "")) : null); root.probeNext() }
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
    function status(): string {
      var base = root.nodes.length + " graves · " + root.reachableCount + " reachable"
      return base + " · " + root.fleetT3Feeds + " T3 feed" + (root.fleetT3Feeds === 1 ? "" : "s") + " · " + root.fleetT3Working + " working · " + root.fleetT3Attention + " need you"
    }
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    iconComponent: Component { GraveIcon { iconSize: Style.font.icon; fontFamily: root.fontFamily; color: root.nodes.length ? (root.warningCount > 0 || root.fleetT3Attention > 0 ? root.urgent : root.foreground) : root.dim; badgeCount: root.warningCount + root.fleetT3Attention; breathing: root.refreshing || root.fleetT3Working > 0 } }
    tooltipText: root.nodes.length ? "Gravedecay · " + root.reachableCount + "/" + root.nodes.length + " reachable" + (root.warningCount ? " · " + root.warningCount + " restless" : "") + (root.fleetT3Working ? " · " + root.fleetT3Working + " T3 working" : "") + (root.fleetT3Attention ? " · " + root.fleetT3Attention + " need you" : "") + (!root.warningCount && !root.fleetT3Working && !root.fleetT3Attention ? " · buried, not broken" : "") : (root.refreshing ? "Gravedecay · checking beneath the soil" : "Gravedecay · no graves found")
    onPressed: function(code) { if (code === Qt.RightButton || code === Qt.MiddleButton) root.refresh(); else root.toggle() }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(420))
    contentHeight: panel.fittedContentHeight(content.implicitHeight, Style.space(660))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onMoveRequested: function(dx, dy) { if (dx) root.selectRelative(dx); if (dy) panelFlick.contentY = Model.clamp(panelFlick.contentY + dy * Style.space(54), 0, Math.max(0, panelFlick.contentHeight - panelFlick.height)) }
      onActivateRequested: root.openDashboard()
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(text) { if (text === "r" || text === "R") root.refresh(); else if (text === "d" || text === "D") root.openDashboard() }

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

          PanelHero {
            width: parent.width
            title: root.current ? (root.current.summary.node.host || root.current.name) : "Gravedecay"
            meta: root.current ? String(root.current.summary.node.platform || "unknown") + " · " + String(root.current.summary.node.mode || "unknown") : (root.refreshing ? "DISCOVERING THE TAILNET" : "NO APPLIANCES REACHABLE")
            detail: root.current ? Model.stateLabel(root.current) : ""
            foreground: root.stateColor
            fontFamily: root.fontFamily
            iconComponent: Component { GraveIcon { iconSize: Style.font.display; fontFamily: root.fontFamily; color: root.stateColor; breathing: root.refreshing || root.currentT3Counts.working > 0 } }
            trailingControl: Component { PanelActionButton { iconText: "󰑐"; tooltipText: "Refresh graves"; foreground: root.foreground; fontFamily: root.fontFamily; onClicked: root.refresh() } }
          }

          RowLayout {
            visible: root.nodes.length > 1
            width: parent.width
            spacing: Style.space(8)
            Dropdown { id: nodePicker; Layout.fillWidth: true; showLabel: false; options: root.nodes.map(function(node) { return { value: node.id, label: (node.reachable ? "" : "☠ ") + node.name } }); onChanged: function(value) { root.selectedId = value; root.phraseIndex = 0 }; Connections { target: root; function onSelectedIdChanged() { nodePicker.value = root.selectedId } } }
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

          Text { width: parent.width; topPadding: Style.space(3); text: root.phrase.toUpperCase(); color: root.currentState === "warning" ? root.urgent : root.dim; font.family: root.fontFamily; font.pixelSize: Style.font.caption; font.bold: true; font.letterSpacing: 1.2; horizontalAlignment: Text.AlignHCenter }
          Text { width: parent.width; text: "←/→ changes grave · r exhumes · enter opens · esc buries"; color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.35); font.family: root.fontFamily; font.pixelSize: Style.font.caption; horizontalAlignment: Text.AlignHCenter }
        }
      }
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
