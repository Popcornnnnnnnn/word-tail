# WordTail Pro

## Open-core philosophy

Everything in WordTail v0.8.3 stays free and open source under the MIT license forever. That includes autocomplete, KeyStats, typing insights, CRDT sync, and the updater. Pro funds continued development through new workflow tools.

## What WordTail Pro unlocks

| Capability | What you can do |
| --- | --- |
| Domain Vocabulary Packs (`domainLexiconPacks`) | Enable six curated packs and import or export custom `.wordtailpack` files. |
| Snippet Studio (`snippetStudio`) | Expand explicit triggers into snippets with date, time, ISO date, clipboard, and cursor macros. |
| Per-App Writing Profiles (`appWritingProfiles`) | Set capitalization, correction, spacing, and vocabulary preferences per app. |
| Bilingual Smart Spacing (`bilingualSpacing`) | Get English completions next to CJK text and add spaces at CJK–English boundaries on acceptance. |
| Typing Wrapped & Reports (`wrappedAndReports`) | Export light or dark posters in 3:4 and 16:9, plus CSV and Markdown activity reports. |

Try all five features for 14 days on your Mac with no card required. The planned collector license costs **$15–$19 USD once** and covers personal use across multiple Macs.

## Offline Ed25519 license issuance

1. Generate the signing keypair on an offline machine with `swift scripts/generate_license.swift --keygen`. Back up the private key securely and configure WordTail with the matching public key.
2. Use Creem for international checkout, including Alipay, and 面包多 for mainland China. For webhook fulfillment, verify the provider's signed payment event and confirm the product and payment status. Record fulfillment by order ID so webhook retries return the same license. For manual fulfillment, verify the order in the provider dashboard.
3. Issue the buyer's key with `swift scripts/generate_license.swift --sign` using the private key and the confirmed order details. Keep the private key on the offline signing machine. A webhook can queue verified orders for signing and deliver the resulting key once it is available.
4. Deliver the `WTPRO-…` key and have the buyer paste it into WordTail Pro settings on each Mac. WordTail verifies the signature on the device using the public key. Activation requires zero runtime license servers or telemetry.

The signing commands are for the license issuer. The purchase links in settings are placeholders until checkout is configured.
