.pragma library

function cleanDnsName(value) {
    return String(value || "").replace(/\.$/, "")
}

function safeDnsName(value) {
    var dns = cleanDnsName(value).toLowerCase()
    return dns.length <= 253 && /^(?=.{1,253}$)(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}$/.test(dns) ? dns : ""
}

function safePath(value) {
    var path = String(value || "")
    return /^\/(?!\/)(?!.*[\\\x00-\x1f\x7f])/.test(path) ? path : ""
}

function safeDesktopEntry(value) {
    var entry = String(value || "").trim()
    return /^[A-Za-z0-9_.-]+\.desktop$/.test(entry) ? entry : ""
}

function safeHyprAddress(value) {
    var address = String(value || "").toLowerCase()
    return /^0x[0-9a-f]+$/.test(address) ? address : ""
}

function number(value, fallback) {
    var parsed = Number(value)
    return isFinite(parsed) ? parsed : fallback
}

function clamp(value, low, high) {
    return Math.max(low, Math.min(high, number(value, low)))
}

function problems(summaryValue) {
    if (!summaryValue || !summaryValue.health) return 0
    return Math.max(0, number(summaryValue.health.services_failed, 0))
        + Math.max(0, number(summaryValue.health.containers_problem, 0))
}

function state(node) {
    if (!node || node.reachable === false) return "unreachable"
    if (problems(node.summary) > 0) return "warning"
    var activity = node.summary && node.summary.activity ? node.summary.activity : {}
    if (number(activity.sessions_live, 0) > 0) return "active"
    if (t3Counts(node.t3Activity).active > 0) return "active"
    if (number(activity.sessions_frozen, 0) > 0) return "frozen"
    return "healthy"
}

function stateLabel(node) {
    var value = state(node)
    if (value === "unreachable") return "UNREACHABLE"
    if (value === "warning") {
        var count = problems(node.summary)
        return count + " ISSUE" + (count === 1 ? "" : "S")
    }
    if (value === "active") return "GRAVEYARD SHIFT"
    if (value === "frozen") return "IN TORPOR"
    return "HEALTHY"
}

function formatDuration(seconds) {
    var total = Math.max(0, Math.floor(number(seconds, 0)))
    var days = Math.floor(total / 86400)
    var hours = Math.floor((total % 86400) / 3600)
    var minutes = Math.floor((total % 3600) / 60)
    if (days > 0) return days + "d " + hours + "h"
    if (hours > 0) return hours + "h " + minutes + "m"
    if (minutes > 0) return minutes + "m"
    return total + "s"
}

function formatAge(timestamp, nowMs) {
    var parsed = typeof timestamp === "number" ? timestamp : new Date(String(timestamp || "")).getTime()
    if (!isFinite(parsed)) return "unknown"
    var seconds = Math.max(0, Math.floor((number(nowMs, Date.now()) - parsed) / 1000))
    if (seconds < 10) return "just now"
    if (seconds < 60) return seconds + "s ago"
    if (seconds < 3600) return Math.floor(seconds / 60) + "m ago"
    if (seconds < 86400) return Math.floor(seconds / 3600) + "h ago"
    return Math.floor(seconds / 86400) + "d ago"
}

function phraseBucket(node) {
    var value = state(node)
    if (value === "unreachable") return ["Nothing answers from the crypt", "Lost beyond the veil", "The soil has gone cold"]
    if (value === "warning") return ["The dead are restless", "Something stirs below", "Rot in the machinery"]
    if (value === "active") return ["Your agents work the graveyard shift", "No rest for the deployed", "The box never sleeps. Neither do they"]
    if (value === "frozen") return ["The agents lie in torpor", "Cold storage, warm intent", "Waiting beneath the frost"]
    return ["Six feet down, five nines up", "Rest in production", "Buried, not broken", "Dig once, ship forever"]
}

function candidates(status) {
    var nodes = []
    if (!status || typeof status !== "object") return nodes
    if (status.Self) nodes.push(status.Self)
    var peers = status.Peer || {}
    for (var key in peers) nodes.push(peers[key])
    var seen = {}
    return nodes.filter(function(node) {
        var dns = safeDnsName(node && node.DNSName)
        var id = String((node && (node.ID || node.StableID || node.NodeID)) || "")
        if (!node || node.Online !== true || !dns || !id || seen[id]) return false
        seen[id] = true
        return true
    }).map(function(node) { return { id: String(node.ID || node.StableID || node.NodeID), dns: safeDnsName(node.DNSName), name: String(node.HostName || safeDnsName(node.DNSName)) } })
}

function summary(raw) {
    try {
        var value = JSON.parse(String(raw || ""))
        if (value.product !== "gravedecay" || value.api_version !== 1 || !value.node || !value.resources || !value.activity || !value.health || !value.links) return null
        return value
    } catch (_) { return null }
}

function t3Activity(raw) {
    try {
        var value = JSON.parse(String(raw || ""))
        var statuses = { ok: true, stale: true, disabled: true, unauthorized: true, unreachable: true }
        if (!value || !statuses[value.status] || !Array.isArray(value.threads)) return null
        var phases = { waiting_approval: true, waiting_input: true, failed: true, starting: true, working: true, completed: true }
        var threads = value.threads.filter(function(thread) {
            return thread && typeof thread === "object" && phases[thread.phase]
        }).slice(0, 50)
        return { status: value.status, updated_at: value.updated_at || null, threads: threads }
    } catch (_) { return null }
}

function t3Counts(activity) {
    var counts = { working: 0, attention: 0, failed: 0, completed: 0, active: 0 }
    var threads = activity && Array.isArray(activity.threads) ? activity.threads : []
    for (var i = 0; i < threads.length; i++) {
        var phase = threads[i] && threads[i].phase
        if (phase === "working" || phase === "starting") counts.working++
        else if (phase === "waiting_approval" || phase === "waiting_input") counts.attention++
        else if (phase === "failed") counts.failed++
        else if (phase === "completed") counts.completed++
    }
    counts.active = counts.working + counts.attention
    return counts
}

function t3Available(activity) {
    return !!activity && (activity.status === "ok" || activity.status === "stale")
}

function actionableT3Threads(activity, limit) {
    var threads = activity && Array.isArray(activity.threads) ? activity.threads : []
    var priority = { waiting_approval: 0, waiting_input: 1, failed: 2, working: 3, starting: 4 }
    return threads.filter(function(thread) {
        return thread && priority[thread.phase] !== undefined
    }).sort(function(a, b) {
        return priority[a.phase] - priority[b.phase]
    }).slice(0, Math.max(0, number(limit, 5)))
}

function activityUrl(nodeDns, value) {
    var dns = safeDnsName(nodeDns)
    if (!dns) return ""
    var raw = String(value || "")
    var path = safePath(raw)
    if (path) return "https://" + dns + path

    var loopback = /^http:\/\/(?:127\.0\.0\.1|localhost)(?::[0-9]{1,5})?(\/.*)$/i.exec(raw)
    if (loopback) {
        path = safePath(loopback[1])
        return path ? "https://" + dns + path : ""
    }

    var remote = /^https:\/\/([A-Za-z0-9.-]+\.ts\.net)(?::([0-9]{1,5}))?(\/.*)$/i.exec(raw)
    if (!remote) return ""
    var remoteDns = safeDnsName(remote[1])
    var port = remote[2] ? number(remote[2], 0) : 443
    path = safePath(remote[3])
    if (!remoteDns || port < 1 || port > 65535 || !path) return ""
    return "https://" + remoteDns + (remote[2] ? ":" + String(port) : "") + path
}

// ---- Shared text and identity helpers ------------------------------------

// Remote text is shown as plain text only; drop control characters and cap it.
function cleanText(value, max) {
    var text = String(value === null || value === undefined ? "" : value).replace(/[\x00-\x08\x0b-\x1f\x7f]/g, "")
    var limit = Math.max(0, number(max, 4000))
    return text.length > limit ? text.slice(0, limit - 1) + "…" : text
}

function firstLine(value, max) {
    return cleanText(String(value || "").split("\n").filter(function(line) { return line.trim() !== "" })[0] || "", max)
}

function safeDiggerName(value) {
    var name = String(value || "")
    return /^[a-z][a-z0-9-]{1,19}$/.test(name) ? name : ""
}

function safeId(value) {
    var id = String(value || "")
    return /^[0-9]{10}-[0-9a-f]{32}$/.test(id) ? id : ""
}

// Conversation, turn and request IDs: Unix seconds, a hyphen, 32 hex digits.
function newId(nowMs, random) {
    var rand = typeof random === "function" ? random : Math.random
    var hex = ""
    for (var i = 0; i < 32; i++) hex += Math.floor(rand() * 16).toString(16)
    var seconds = String(Math.floor(number(nowMs, Date.now()) / 1000))
    while (seconds.length < 10) seconds = "0" + seconds
    return seconds.slice(-10) + "-" + hex
}

function parseJson(raw) {
    if (raw && typeof raw === "object") return raw
    try { return JSON.parse(String(raw || "")) } catch (_) { return null }
}

// "body\nHTTP 200\n" from gravedecay-api request.
function apiResponse(raw, exitCode) {
    var text = String(raw || "")
    var at = text.lastIndexOf("\nHTTP ")
    var code = at >= 0 && number(exitCode, 1) === 0 ? number(text.slice(at + 6).trim(), 0) : 0
    var data = parseJson(at >= 0 ? text.slice(0, at) : "")
    var ok = code >= 200 && code < 300 && !!data && typeof data === "object"
    var message = ""
    if (!ok) {
        if (code === 0) message = number(exitCode, 1) === 0 ? "The grave did not answer over Tailscale" : "Request refused by the plugin"
        else message = cleanText(data && (data.output || data.message || data.error) || ("HTTP " + code), 300)
    }
    return { ok: ok, code: code, data: ok ? data : null, error: data && typeof data.error === "string" ? data.error : "", message: message }
}

function compareVersions(a, b) {
    var x = /^v?(\d+)\.(\d+)\.(\d+)$/.exec(String(a || "")), y = /^v?(\d+)\.(\d+)\.(\d+)$/.exec(String(b || ""))
    if (!x || !y) return 0
    for (var i = 1; i <= 3; i++) if (Number(x[i]) !== Number(y[i])) return Number(x[i]) > Number(y[i]) ? 1 : -1
    return 0
}

// ---- Probe -----------------------------------------------------------------

function capabilities(raw) {
    var value = parseJson(raw)
    if (!value || value.product !== "gravedecay" || value.api_version !== 1 || !value.routes) return null
    function routes(list) {
        var map = {}
        if (Array.isArray(list)) for (var i = 0; i < list.length; i++) if (typeof list[i] === "string") map[list[i]] = true
        return map
    }
    var get = routes(value.routes.GET), post = routes(value.routes.POST)
    var keeper = value.keeper && typeof value.keeper === "object" && get.keeper && post["keeper/turn"]
        ? { provider: cleanText(value.keeper.provider, 20), model: cleanText(value.keeper.model, 60) } : null
    return {
        platform: cleanText(value.platform, 20),
        keeper: keeper,
        diggers: !!(get.diggers && post["diggers/ask"]),
        releases: !!(get["admin/releases"] && get["admin/update-status"]),
        upgrade: !!post["admin/upgrade"]
    }
}

function diggers(raw) {
    var value = parseJson(raw)
    var rows = value && Array.isArray(value.diggers) ? value.diggers : []
    return rows.filter(function(row) { return row && typeof row === "object" && safeDiggerName(row.name) }).slice(0, 32).map(function(row) {
        var today = row.today || {}, limits = row.limits || {}, slack = row.slack && typeof row.slack === "object" ? row.slack : null
        var prompts = Array.isArray(row.prompts) ? row.prompts : []
        return {
            name: row.name,
            provider: cleanText(row.provider, 20),
            identity: cleanText(row.identity, 30),
            repo: cleanText(row.repo, 80),
            enabled: row.enabled === true,
            live: row.live === true,
            paused: row.paused === true,
            pause: row.pause === "gaming" || row.pause === "budget" ? row.pause : "",
            budgetReason: cleanText(row.budget_reason, 200),
            loggedIn: row.loggedIn === true ? true : row.loggedIn === false ? false : null,
            queue: Math.max(0, Math.floor(number(row.queue, 0))),
            running: safeId(row.running),
            today: { turns: Math.max(0, number(today.turns, 0)), usd: Math.max(0, number(today.usd, 0)) },
            limits: { turns: Math.max(0, number(limits.turns, 0)), usd: Math.max(0, number(limits.usd, 0)) },
            slack: slack ? { connected: slack.connected === true, error: cleanText(slack.error, 200), approvals: Math.max(0, Math.floor(number(slack.approvals, 0))) } : null,
            lastVerdict: cleanText(row.last_verdict, 40),
            prompts: prompts.filter(function(p) { return p && typeof p.label === "string" && typeof p.template === "string" }).slice(0, 8)
                .map(function(p) { return { label: cleanText(p.label, 40), template: cleanText(p.template, 2000) } })
        }
    })
}

function diggerStatus(row) {
    if (!row) return ""
    if (!row.enabled) return "disabled"
    if (row.loggedIn === false) return "signed out"
    if (!row.live) return "loop offline"
    if (row.pause === "budget") return "budget paused"
    if (row.pause === "gaming" || row.paused) return "gaming pause"
    if (row.running) return "digging"
    if (row.queue > 0) return row.queue + " queued"
    return "idle"
}

function diggerApprovals(row) {
    return row && row.slack ? row.slack.approvals : 0
}

function diggerNeedsAttention(row) {
    if (!row || !row.enabled) return false
    return diggerApprovals(row) > 0 || row.loggedIn === false || !row.live || row.pause === "budget"
}

function budgetLabel(row) {
    if (!row) return ""
    var parts = []
    if (row.limits.usd > 0) parts.push("$" + row.today.usd.toFixed(2) + "/" + row.limits.usd.toFixed(0))
    if (row.limits.turns > 0) parts.push(row.today.turns + "/" + row.limits.turns + " turns")
    return parts.join(" · ")
}

var CONVERSATION_STATES = { idle: true, queued: true, running: true, succeeded: true, failed: true, timed_out: true, cancelled: true, interrupted: true }

function conversationRows(list) {
    var rows = Array.isArray(list) ? list : []
    return rows.filter(function(row) { return row && safeId(row.id) }).map(function(row) {
        return {
            id: row.id,
            state: CONVERSATION_STATES[row.state] ? row.state : "idle",
            phase: cleanText(row.phase, 20),
            summary: firstLine(row.summary, 140),
            requestedBy: cleanText(row.requested_by, 60),
            updatedAt: number(row.updated_at, 0)
        }
    }).sort(function(a, b) { return b.updatedAt - a.updatedAt }).slice(0, 20)
}

function keeperList(raw) {
    var value = parseJson(raw)
    if (!value || !Array.isArray(value.conversations)) return null
    return { provider: cleanText(value.provider, 20), model: cleanText(value.model, 60), conversations: conversationRows(value.conversations) }
}

function probe(raw) {
    var value = parseJson(raw)
    if (!value || value.reachable !== true) return null
    var summaryValue = summary(value.summary)
    if (!summaryValue) return null
    var caps = capabilities(value.capabilities)
    return {
        summary: summaryValue,
        t3Activity: t3Activity(value.t3),
        capabilities: caps,
        diggers: caps && caps.diggers ? diggers(value.diggers) : [],
        keeper: caps && caps.keeper ? keeperList(value.keeper) : null
    }
}

// ---- Conversations -----------------------------------------------------------

var EVENT_TYPES = { text: true, tool_call: true, tool_result: true, done: true, error: true }

function conversation(value) {
    if (!value || typeof value !== "object" || !safeId(value.id)) return null
    var events = Array.isArray(value.events) ? value.events : []
    var clean = events.filter(function(event) {
        return event && EVENT_TYPES[event.type] && isFinite(Number(event.seq))
    }).map(function(event) {
        return { seq: Number(event.seq), type: event.type, name: cleanText(event.name, 80), text: cleanText(event.text, 16384), at: number(event.at, 0) }
    })
    var result = value.result && typeof value.result === "object" ? value.result : null
    return {
        id: value.id,
        state: CONVERSATION_STATES[value.state] ? value.state : "idle",
        phase: value.phase === "open" || value.phase === "finishing" || value.phase === "finished" ? value.phase : "",
        settling: value.settling === true,
        summary: cleanText(value.summary, 2000),
        message: cleanText(value.message, 500),
        queued: Math.max(0, Math.floor(number(value.queued, 0))),
        branch: cleanText(value.branch, 120),
        result: result ? { verdict: cleanText(result.verdict, 40), summary: cleanText(result.summary, 2000) } : null,
        refused: Array.isArray(value.refused) ? value.refused.slice(-3).map(function(r) { return cleanText(r && r.reason, 300) }) : [],
        events: clean
    }
}

function conversationBusy(record) {
    if (!record) return false
    return record.state === "queued" || record.state === "running" || record.phase === "finishing" || record.settling === true
}

function mergeEvents(existing, incoming) {
    var seen = {}, merged = []
    var all = (Array.isArray(existing) ? existing : []).concat(Array.isArray(incoming) ? incoming : [])
    for (var i = 0; i < all.length; i++) {
        if (seen[all[i].seq]) continue
        seen[all[i].seq] = true
        merged.push(all[i])
    }
    merged.sort(function(a, b) { return a.seq - b.seq })
    return merged.slice(-400)
}

function lastSeq(events) {
    var max = 0
    for (var i = 0; i < (events || []).length; i++) max = Math.max(max, events[i].seq)
    return max
}

function toolLabel(name) {
    return String(name || "tool").replace(/^mcp__/, "").replace(/^keeper__/, "").replace(/__/g, " · ")
}

// Transcript lines for display: what was said, which tools ran, what failed.
function chatLines(events, agentName, limit) {
    var lines = []
    var list = Array.isArray(events) ? events : []
    for (var i = 0; i < list.length; i++) {
        var event = list[i]
        if (event.type === "text") {
            if (event.name === "owner") lines.push({ role: "owner", label: "YOU", text: event.text })
            else if (event.name === "runner") lines.push({ role: "note", label: "RUNNER", text: event.text })
            else lines.push({ role: "agent", label: String(agentName || "AGENT").toUpperCase(), text: event.text })
        } else if (event.type === "tool_call") {
            var args = firstLine(event.text, 90)
            lines.push({ role: "tool", label: "", text: "→ " + toolLabel(event.name) + (args && args !== "{}" ? " " + args : "") })
        } else if (event.type === "error") {
            lines.push({ role: "error", label: "ERROR", text: event.text || "The turn failed" })
        }
    }
    return lines.slice(-Math.max(1, number(limit, 80)))
}

function hasOwnerText(events, text) {
    var wanted = String(text || "").trim()
    for (var i = 0; i < (events || []).length; i++)
        if (events[i].type === "text" && events[i].name === "owner" && events[i].text.trim() === wanted) return true
    return false
}

function conversationStateLabel(record) {
    if (!record) return "new conversation"
    if (record.phase === "finishing") return "finishing"
    if (record.settling) return "settling"
    if (record.state === "queued") return record.queued > 1 ? record.queued + " requests queued" : "queued for the digger"
    if (record.state === "running") return "thinking"
    if (record.phase === "finished") return "finished" + (record.result && record.result.verdict ? " · " + record.result.verdict : "")
    return String(record.state).replace(/_/g, " ")
}

// ---- Updates -----------------------------------------------------------------

function releaseInfo(raw) {
    var value = parseJson(raw)
    if (!value || typeof value !== "object") return null
    var current = /^v\d+\.\d+\.\d+$/.test(String(value.current || "")) ? value.current : ""
    var releases = Array.isArray(value.releases) ? value.releases.filter(function(tag) { return /^v\d+\.\d+\.\d+$/.test(String(tag)) }) : []
    var latest = ""
    if (value.available === true && /^v\d+\.\d+\.\d+$/.test(String(value.latest || ""))) latest = value.latest
    else if (value.available === undefined && current) {
        for (var i = 0; i < releases.length; i++)
            if (compareVersions(releases[i], current) > 0 && (!latest || compareVersions(releases[i], latest) > 0)) latest = releases[i]
    }
    return {
        current: current,
        checkout: cleanText(value.checkout, 120),
        channel: value.channel === "edge" ? "edge" : "release",
        latest: latest,
        native: value.available !== undefined,
        newestRelease: releases.length ? releases.slice().sort(function(a, b) { return compareVersions(b, a) })[0] : ""
    }
}

function updateStatus(raw) {
    var value = raw && typeof raw === "object" ? raw : parseJson(raw)
    var states = { idle: true, queued: true, running: true, ok: true, failed: true }
    if (!value || !states[value.state]) return null
    return { state: value.state, attempt: cleanText(value.attempt, 80), message: firstLine(value.message || value.log, 200), dashboardCurrent: value.dashboard_current !== false }
}

function releaseLabel(info) {
    if (!info) return ""
    if (info.current) return info.current + (info.channel === "edge" ? " · edge" : "")
    return info.checkout ? "checkout " + info.checkout : "development checkout"
}

function pluginUpdate(raw) {
    var value = parseJson(raw)
    if (!value || typeof value !== "object") return null
    var local = cleanText(value.local, 20), remote = cleanText(value.remote, 20), behind = Math.max(0, Math.floor(number(value.behind, 0)))
    return {
        git: value.git === true,
        local: local,
        remote: remote,
        behind: behind,
        dirty: value.dirty === true,
        error: cleanText(value.error, 120),
        available: value.git === true && behind > 0
    }
}

function pluginUpdateLabel(info) {
    if (!info) return ""
    if (!info.git) return "Installed without git · reinstall with omarchy plugin add to enable updates"
    if (info.error) return "Update check failed · " + info.error
    if (!info.available) return "Plugin " + info.local + " is up to date"
    if (info.remote && compareVersions(info.remote, info.local) > 0) return "Plugin " + info.remote + " is available (you have " + info.local + ")"
    return info.behind + " new plugin change" + (info.behind === 1 ? "" : "s") + " available"
}
