import Foundation

enum DefaultData {
    // MARK: DNS servers

    static var servers: [DNSServer] {
        [
            DNSServer(name: "Current System DNS", provider: "System", address: "", isSystem: true, colorHex: "#8E8E93",
                      notes: "Whatever your Mac uses right now (usually your router or ISP)"),

            udp("Cloudflare", "Cloudflare", "1.1.1.1", "#F38020"),
            udp("Cloudflare Secondary", "Cloudflare", "1.0.0.1", "#F38020"),
            udp("Cloudflare Malware Blocking", "Cloudflare", "1.1.1.2", "#F38020", on: false),
            udp("Cloudflare Family", "Cloudflare", "1.1.1.3", "#F38020", on: false),

            udp("Google Public DNS", "Google", "8.8.8.8", "#4285F4"),
            udp("Google Secondary", "Google", "8.8.4.4", "#4285F4"),

            udp("Quad9", "Quad9", "9.9.9.9", "#E0218A", notes: "Blocks malicious domains"),
            udp("Quad9 Secondary", "Quad9", "149.112.112.112", "#E0218A", on: false),
            udp("Quad9 Unfiltered", "Quad9", "9.9.9.10", "#E0218A", on: false),
            udp("Quad9 with ECS", "Quad9", "9.9.9.11", "#E0218A", on: false),

            udp("OpenDNS Home", "OpenDNS", "208.67.222.222", "#00A3E0"),
            udp("OpenDNS Secondary", "OpenDNS", "208.67.220.220", "#00A3E0", on: false),
            udp("OpenDNS FamilyShield", "OpenDNS", "208.67.222.123", "#00A3E0", on: false),

            udp("AdGuard DNS", "AdGuard", "94.140.14.14", "#68BC71", notes: "Blocks ads and trackers"),
            udp("AdGuard Non-filtering", "AdGuard", "94.140.14.140", "#68BC71", on: false),
            udp("AdGuard Family", "AdGuard", "94.140.14.15", "#68BC71", on: false),

            udp("Control D", "Control D", "76.76.2.0", "#5D5FEF", notes: "Unfiltered"),
            udp("Control D Malware", "Control D", "76.76.2.1", "#5D5FEF", on: false),
            udp("Alternate DNS", "Alternate DNS", "76.76.19.19", "#F59E0B", on: false),

            udp("CleanBrowsing Security", "CleanBrowsing", "185.228.168.9", "#1FA67A"),
            udp("CleanBrowsing Family", "CleanBrowsing", "185.228.168.168", "#1FA67A", on: false),

            udp("Comodo Secure DNS", "Comodo", "8.26.56.26", "#C8102E"),
            udp("Level3 / Lumen", "Level3", "4.2.2.1", "#0072CE"),
            udp("DNS.SB", "DNS.SB", "185.222.222.222", "#3A86FF"),
            udp("UltraDNS Public", "UltraDNS", "64.6.64.6", "#7B3FE4"),
            udp("Hurricane Electric", "Hurricane Electric", "74.82.42.42", "#2B5797"),
            udp("Gcore DNS", "Gcore", "95.85.95.85", "#FF4C00"),
            udp("DNS4EU Unfiltered", "DNS4EU", "86.54.11.100", "#003399", on: false),
            udp("NextDNS (anycast)", "NextDNS", "45.90.28.0", "#007BFF", on: false),
            udp("Yandex DNS", "Yandex", "77.88.8.8", "#FC3F1D", on: false),
            udp("Quad101 (TWNIC)", "Quad101", "101.101.101.101", "#0CA678", on: false),

            udp("Cloudflare IPv6", "Cloudflare", "2606:4700:4700::1111", "#F38020", on: false, notes: "Needs IPv6 internet"),
            udp("Google IPv6", "Google", "2001:4860:4860::8888", "#4285F4", on: false, notes: "Needs IPv6 internet"),
            udp("Quad9 IPv6", "Quad9", "2620:fe::fe", "#E0218A", on: false, notes: "Needs IPv6 internet"),

            dot("Cloudflare DoT", "Cloudflare", "one.one.one.one", "#F38020"),
            dot("Google DoT", "Google", "dns.google", "#4285F4"),
            dot("Quad9 DoT", "Quad9", "dns.quad9.net", "#E0218A"),
            dot("AdGuard DoT", "AdGuard", "dns.adguard-dns.com", "#68BC71"),
            dot("OpenDNS DoT", "OpenDNS", "dns.opendns.com", "#00A3E0"),
            dot("Control D DoT", "Control D", "p0.freedns.controld.com", "#5D5FEF"),
            dot("Mullvad DoT", "Mullvad", "dns.mullvad.net", "#294D73"),

            doh("Cloudflare DoH", "Cloudflare", "https://cloudflare-dns.com/dns-query", "#F38020"),
            doh("Google DoH", "Google", "https://dns.google/dns-query", "#4285F4"),
            doh("Quad9 DoH", "Quad9", "https://dns.quad9.net/dns-query", "#E0218A"),
            doh("AdGuard DoH", "AdGuard", "https://dns.adguard-dns.com/dns-query", "#68BC71"),
            doh("OpenDNS DoH", "OpenDNS", "https://doh.opendns.com/dns-query", "#00A3E0"),
            doh("Control D DoH", "Control D", "https://freedns.controld.com/p0", "#5D5FEF"),
            doh("Mullvad DoH", "Mullvad", "https://dns.mullvad.net/dns-query", "#294D73"),
        ]
    }

    /// Bumped whenever servers are added to the defaults, so lists saved earlier get them once (see `AppStore`).
    static let serverCatalog = 1

    /// The default servers added since `catalog`.
    static func serversAdded(after catalog: Int) -> [DNSServer] {
        catalog < 1 ? servers.filter { $0.proto == .dot } : []
    }

    private static func udp(_ name: String, _ provider: String, _ address: String, _ color: String, on: Bool = true, notes: String = "") -> DNSServer {
        DNSServer(name: name, provider: provider, address: address, proto: .udp, isEnabled: on, colorHex: color, notes: notes)
    }

    /// DoT entries start switched off, like DoH: macOS network settings can't use them directly.
    private static func dot(_ name: String, _ provider: String, _ host: String, _ color: String) -> DNSServer {
        DNSServer(name: name, provider: provider, address: host, port: 853, proto: .dot, isEnabled: false, colorHex: color)
    }

    /// DoH entries start switched off: they are slower by design (HTTPS) and can't be set in macOS network settings directly.
    private static func doh(_ name: String, _ provider: String, _ url: String, _ color: String) -> DNSServer {
        DNSServer(name: name, provider: provider, address: url, port: 443, proto: .doh, isEnabled: false, colorHex: color)
    }

    // MARK: Websites

    static var websites: [Website] {
        topSites.enumerated().map { index, entry in
            Website(domain: entry.0, category: entry.1, rank: index + 1)
        }
    }

    /// 100 popular websites, roughly in order of popularity: the most visited worldwide, plus travel, gaming and crypto sites.
    static let topSites: [(String, WebsiteCategory)] = [
        ("google.com", .search),
        ("youtube.com", .streaming),
        ("facebook.com", .social),
        ("instagram.com", .social),
        ("wikipedia.org", .reference),
        ("x.com", .social),
        ("whatsapp.com", .communication),
        ("chatgpt.com", .ai),
        ("reddit.com", .social),
        ("bing.com", .search),
        ("yahoo.com", .search),
        ("amazon.com", .shopping),
        ("tiktok.com", .social),
        ("linkedin.com", .social),
        ("netflix.com", .streaming),
        ("live.com", .tech),
        ("microsoft.com", .tech),
        ("office.com", .tech),
        ("duckduckgo.com", .search),
        ("twitch.tv", .streaming),
        ("kick.com", .streaming),
        ("pinterest.com", .social),
        ("discord.com", .communication),
        ("github.com", .tech),
        ("apple.com", .tech),
        ("icloud.com", .tech),
        ("openai.com", .ai),
        ("outlook.com", .communication),
        ("zoom.us", .communication),
        ("ebay.com", .shopping),
        ("paypal.com", .finance),
        ("binance.com", .finance),
        ("spotify.com", .streaming),
        ("imdb.com", .reference),
        ("msn.com", .news),
        ("weather.com", .news),
        ("cnn.com", .news),
        ("bbc.com", .news),
        ("nytimes.com", .news),
        ("theguardian.com", .news),
        ("aliexpress.com", .shopping),
        ("temu.com", .shopping),
        ("walmart.com", .shopping),
        ("etsy.com", .shopping),
        ("shopify.com", .shopping),
        ("mobile.de", .shopping),
        ("booking.com", .travel),
        ("airbnb.com", .travel),
        ("tripadvisor.com", .travel),
        ("expedia.com", .travel),
        ("trip.com", .travel),
        ("kayak.com", .travel),
        ("ryanair.com", .travel),
        ("wizzair.com", .travel),
        ("canva.com", .tech),
        ("figma.com", .tech),
        ("fandom.com", .reference),
        ("roblox.com", .gaming),
        ("telegram.org", .communication),
        ("vk.com", .social),
        ("quora.com", .reference),
        ("stackoverflow.com", .tech),
        ("adobe.com", .tech),
        ("dropbox.com", .tech),
        ("wordpress.com", .tech),
        ("tumblr.com", .social),
        ("claude.ai", .ai),
        ("grok.com", .ai),
        ("gemini.google.com", .ai),
        ("perplexity.ai", .ai),
        ("character.ai", .ai),
        ("deepseek.com", .ai),
        ("openrouter.ai", .ai),
        ("samsung.com", .tech),
        ("cloudflare.com", .tech),
        ("espn.com", .news),
        ("foxnews.com", .news),
        ("dailymail.com", .news),
        ("washingtonpost.com", .news),
        ("reuters.com", .news),
        ("forbes.com", .news),
        ("indeed.com", .other),
        ("hulu.com", .streaming),
        ("disneyplus.com", .streaming),
        ("primevideo.com", .streaming),
        ("taobao.com", .shopping),
        ("imgur.com", .social),
        ("medium.com", .reference),
        ("notion.so", .tech),
        ("slack.com", .communication),
        ("steampowered.com", .gaming),
        ("epicgames.com", .gaming),
        ("riotgames.com", .gaming),
        ("uber.com", .travel),
        ("snapchat.com", .social),
        ("threads.com", .social),
        ("target.com", .shopping),
        ("chase.com", .finance),
        ("jup.ag", .finance),
        ("fomo.family", .finance),
    ]
}
