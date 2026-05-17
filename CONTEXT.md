# QUI Domain Context

## Cooldown Manager

### Resolved Cooldown State

A resolved cooldown state is the single runtime factual answer for one Cooldown Manager entry at a moment in time. It includes the selected duration lane (`aura`, `charge`, `cooldown`, `gcd-only`, or `inactive`), the renderable `DurationObject` or clean numeric timing when one exists, source identity, mirror backing, active state, and any unknown/secret-safe state needed by renderers.

The resolved cooldown state is not a frame state and does not own renderer policy. Icons and bars may adapt it to their own visual widgets and decide visual effects such as desaturation, GCD styling, stack text display, and cooldown bling. They should not independently re-decide the duration lane or cooldown activity from raw Blizzard cooldown, aura, or mirror payloads.

Icons and bars should consume the same resolved cooldown state facts. If their visual adapters diverge, the divergence should be in renderer policy only, not in how the runtime state is resolved.

`CDMResolvers` owns resolved cooldown state facts in place. The goal is to deepen that module around this interface rather than introduce a separate parallel module for the same runtime decision.

`CDMBlizzMirror` is a sanitized capture adapter, not the final cooldown authority. It may carry Blizzard child `DurationObject` values, source hints, identity, epoch, active/visibility facts, aura/count/totem facts, and sanitized Cooldown Viewer metadata. `CDMResolvers.ResolveCooldownState` owns the final decision to accept, override, or reject those mirror facts using the explicit entry context and clean live cooldown, charge, GCD, aura, and item facts when they are available. If clean live cooldown info proves a mirror-backed cooldown stale, that rejection belongs in `CDMResolvers`, not in icon or bar renderers.

`CDMResolvers` must not depend on `CDMIcons` or any late-bound icon import hook. `CDMRuntimeQueries` owns source reads, short batch caches, trusted GCD snapshots, charge-duration serials, and charge metadata persistence. `CDMResolvers` consumes that seam and owns cooldown-info classification, mirror charge payload detection, and the final resolved cooldown state facts. Icon-specific renderer policy such as buff-swipe, aura-phase skipping, and GCD-swipe display must enter the resolver through explicit cooldown-state context fields.

`CDMIcons` should not re-export `CDMResolvers` fact APIs under historical icon names. Icon code may keep private adapters that add renderer policy before calling the resolver, but resolved-state facts remain named on `CDMResolvers`; source reads and batch-query state remain named on `CDMRuntimeQueries` / `CDMSources`.

Entry aura-active lookup is a resolver fact exposed as `CDMResolvers.ResolveAuraActiveState`. Icons and visual effects may consume it, but `CDMIcons` should not export historical icon-side aura fact lookups.

The migration target is direct caller consumption of named resolved cooldown state. Legacy positional tuple APIs such as `ResolveIconDurationObject` and aura-only icon wrappers such as `ResolveAuraStateForIcon` are not part of the resolved cooldown state interface; callers should build an explicit context and consume named fields from `ResolveCooldownState`.

Renderer-side cooldown predicates should derive from resolved-state fields already stamped on the icon, especially `mode` / `_resolvedCooldownMode` plus the resolved cooldown-active flag. They should not call a separate resolver helper to re-classify real cooldown state from raw cooldown API payloads.

`CDMIcons` owns the icon runtime update interface and stack text renderer policy, including mirror-bind stack seeding. `CDMIconFactory` owns icon frame lifecycle and mirror binding helpers only; it should not expose icon runtime updates, synthesize fallback runtime state from renderer fields such as `_hasCooldownActive`, `_resolvedCooldownMode`, or `_lastDurObj`, or classify entries to decide stack text behavior.

`CDMIconFactory` may notify `CDMIcons` through the icon runtime lifecycle hooks `OnFactoryIconCreated`, `OnFactoryIconAcquired`, and `OnFactoryIconReleased`. `CDMContainers` may notify `CDMIcons` through `OnContainerIconInteractionRestored` when it restores icon mouse interaction after visibility or edit-mode suppression. Detailed runtime setup/teardown helpers such as cooldown-expiry timer cleanup, custom-bar glow cleanup, profession-quality overlays, click-to-cast attributes, runtime-store clearing, and keybind overlay clearing should stay local behind those hooks.

`CDMIconFactory` owns icon frame lifecycle and pool membership: acquire, release, pool lookup, pool iteration, pool creation, and pool clearing. `CDMIcons` may build icon entry lists and apply renderer state, but it should call factory lifecycle methods instead of re-exporting pool or frame-lifecycle helpers.

Icon row styling is a CDMIcons implementation detail behind lifecycle hooks. Container layout should place/show an icon, then notify CDMIcons through `OnContainerIconPlaced` so row styling and immediate runtime refresh happen together. Non-container layout code that only needs styling may use `OnIconRowConfigApplied`. Mirror binding should notify CDMIcons through `OnFactoryMirrorBound` and `OnFactoryMirrorUnbound`; mirror index storage, mirror index lookup, stored row-style reapplication, and mirror stack seeding stay private behind those hooks. Callers should not invoke broad icon-configuration helpers, mirror-runtime helpers, or generic single-icon cooldown refresh helpers directly.

Icon renderer frame-state helpers such as aura-state application, resolved-state icon adapters, desaturation application, and apply/read cooldown helpers are CDMIcons implementation details. Tests may use the narrow `ApplyResolvedCooldown` seam for renderer behavior, but broader helpers should stay private.

Stack/count text renderer policy is private to `CDMIconStackPolicy` behind `CDMIcons`: mirror authority, aura-application fallback probes, display predicates, and show/hide writes stay behind icon lifecycle hooks and the icon runtime update. Callers should not invoke stack helper fragments directly.

Custom-bar renderer policy is private to `CDMIconCustomBarPolicy` behind `CDMIcons`: active-state adaptation, cooldown/usability visibility, recharge swipe styling, active glow start/stop, and visual-priority checks stay behind the icon runtime update and lifecycle hooks. `CDMShared` owns only the pure custom-bar settings taxonomy and normalization.

GCD swipe flag writes, mirror state lookup, and mirror charge-cycle memory are private icon renderer policy owned by `CDMIconCooldownPolicy` behind `CDMIcons`. Trusted GCD snapshots live behind `CDMRuntimeQueries`. `CDMIcons.ApplyResolvedCooldown` may remain as the narrow renderer test seam, but callers should not reach into individual GCD or mirror charge-cycle helper fragments.

Numeric safety, DurationObject cooldown application, totem predicates, tracker settings lookup, icon-list signatures, and buff layout refresh helpers are private `CDMIcons` implementation details. Inventory cooldown adapters, when needed cross-module, live on `ns.CDMCooldown`, not on `CDMIcons`.

`CDMIcons.HandleRuntimeRefresh(event, ...)` is the external runtime refresh seam for CDM event sources that do not live inside the icon event frame, such as `UNIT_AURA` payloads captured by `CDMSpellData`. Frame-event branching, scoped aura/spell/item refresh walkers, usability reconciliation, charge-duration notifications, and mirror refresh queue helpers are private `CDMIcons` implementation details.

Mutable runtime scratch state is private to `CDMIcons`: scheduler trust flags, batch DB/time hoists, stack-write request flags, event-profile counters, mirror refresh queue/counters, and aura-delta scratch tables must stay behind lifecycle/update seams and observable methods such as `ShouldAllowStackTextWrites`, `RecordEventProfile`, `SnapshotEventProfile`, and `GetCacheStats`.

Alias lookup fragments, swipe batch policy refresh, buff-swipe/aura-phase predicates, and Blizzard mirror icon state sync/debug snapshots are private `CDMIcons` implementation details. The public surface should expose outcomes and lifecycle seams, not those intermediate renderer policy fragments.

`CDMIcons` public names must be categorized in the architecture contract as external seams, debug seams, or narrow test seams. New public names should be rejected unless they are intentionally added to that allowlist with a caller-facing reason.

Container layout may ask `CDMIcons.ShouldContainerLayoutPlaceIcon` whether an icon should occupy a dynamic-layout slot. That hook is the layout-facing seam: it may stamp layout-filter state for later dirty checks, while the underlying filter policy remains private to `CDMIcons`. `CDMContainers` should not call broad icon filter helpers directly.

Resolved cooldown state uses one stable flat table shape with named fields. Hot-path implementations may reuse/clear tables; callers must treat absent fields as unknown or not applicable instead of relying on mode-specific nested payload shapes.

Resolved cooldown state includes stack/count facts when they are known: value, sink text, source, shown/hidden authority, and whether the value came from the Blizzard mirror. Renderers decide how to display those facts, but they should not independently bypass mirror authority to synthesize stack/count text.

Resolved cooldown state includes aura facts when they are known: `auraActive`, `auraInstanceID`, `auraUnit`, `auraData`, `hasExpirationTime`, `durationStateUnknown`, `resolvedAuraSpellID`, and totem identity fields. `active`/`isActive` describes the selected duration lane; `auraActive` describes whether the aura itself is active when aura facts are known. Runtime aura resolution lives behind `CDMAuraRuntime`; callers should not treat `CDMSpellData` aura internals as a separate parallel truth source beside resolved cooldown state.

Runtime activity facts are stored alongside the renderer-applied resolved state in `CDMRuntimeStore`: `isOnCooldown`, `rechargeActive`, `hasCharges`, `hasChargesRemaining`, and `gcdOnly`. `ResolveCooldownActivityState` is now an adapter over those fields with a raw query fallback only for compatibility paths that do not yet have a stored resolved state.

Resolved cooldown state is resolved from an explicit entry context, not by scraping renderer frame fields. Icon and bar adapters build the context from their frame state (`entry`, runtime spell ID, mirror cooldown ID/category, container key, and totem slot). Prior-frame memory such as last-good real cooldown duration objects and charge-cycle identity stays on the renderer frame or runtime store, but when that memory affects cooldown classification it must be passed into the resolver context as named facts so `CDMResolvers` owns the final mode and cooldown-activity decision.

Resolved cooldown state tests should prefer field contract tests. They should assert the named fields that make up the flat resolved state table for representative scenarios, especially selected lane, active/unknown state, source identity, mirror authority, aura identity, expiration state, and stack/count authority. Behavior-oriented tests can still cover end-to-end renderer adaptation, but the resolved state table is itself a stable interface.

### Container Taxonomy

Cooldown Manager container taxonomy separates four concepts that historically shared names:

- A container key is QUI's saved-data/layout identity, such as `essential`, `utility`, `buff`, `trackedBar`, or a custom container key.
- A container type is the legacy persisted family: `cooldown`, `aura`, or `auraBar`. It implies an entry kind for built-in containers, but custom mixed containers may not imply one.
- A container shape is the renderer shape: `icon` or `bar`.
- A mirror category is Blizzard Cooldown Viewer identity: `essential`, `utility`, `buff`, or `trackedBar`.

`CDMShared` owns the canonical built-in container facts and mirror-category predicates. Runtime modules should ask those helpers instead of independently treating `viewerType`, `containerKey`, and Blizzard mirror category as interchangeable strings.

`CDMShared` also owns pure custom-bar settings normalization such as custom-bar container detection and visibility-mode flag normalization. `CDMIcons` owns renderer behavior that consumes those normalized settings, not the normalization interface itself.

### Secret-Safe Blizzard Reference

CDM keeps Blizzard API assumptions local. `docs/blizzard/cdm-api-reference.md` is the maintainer reference, and `tests/api-docs/cdm_blizzard_reference.lua` is the machine-readable policy table used by tests. Runtime decisions about `DurationObject` sources/sinks, unsafe cooldown setters, and secret boolean decode should be traceable to those files rather than to agent prompts or scattered comments.
