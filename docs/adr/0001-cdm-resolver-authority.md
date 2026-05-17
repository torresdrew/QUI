# CDM Resolver Owns Final Cooldown Authority

Status: accepted

Cooldown Manager has two possible authority points for Blizzard mirror-backed cooldowns: `CDMBlizzMirror` can interpret hidden viewer child state, and `CDMResolvers` can resolve the final addon-owned runtime state. We decided that `CDMResolvers.ResolveCooldownState` owns the final resolved cooldown state, including whether a mirror-backed cooldown is accepted, treated as GCD-only for activity side effects, or rejected as inactive when clean live cooldown facts prove the mirror stale.

`CDMBlizzMirror` remains a sanitized capture adapter. It records Blizzard child `DurationObject` values, source hints, identity, epoch, active/visibility facts, aura/count/totem facts, and sanitized Cooldown Viewer metadata, but it does not own final lane or activity policy for QUI-owned icon and bar frames. This keeps mirror trust and stale-mirror rejection local to the resolved cooldown state interface, and prevents icons or bars from independently re-deciding from raw mirror and live cooldown payloads.
