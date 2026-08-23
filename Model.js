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
