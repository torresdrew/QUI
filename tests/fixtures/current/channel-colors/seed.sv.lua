-- Validates round-trip of the new chat.channelColors per-channel color override
-- map. Mixes built-in chat-type keys (SAY, RAID) with a custom channel name
-- ("Trade") to confirm the table survives load → migrate → export → import →
-- save without shape drift.
QUI_DB = {
    profileKeys = {
        ["TestChar - TestRealm"] = "Default",
    },
    profiles = {
        Default = {
            chat = {
                channelColors = {
                    SAY     = { 0.95, 0.95, 0.95 },
                    RAID    = { 1.00, 0.50, 0.00 },
                    ["Trade"] = { 0.40, 0.70, 1.00 },
                },
            },
        },
    },
}
QUIDB = {}
